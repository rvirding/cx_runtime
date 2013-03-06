-module(concurix_runtime).

-behaviour(gen_server).

-export([start/2, start_link/0, stop/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([update_process_info/1, mod_to_service/1, local_translate_initial_call/1, get_current_json/1, mod_to_behaviour/1]).

-include("concurix_runtime.hrl").

start(Filename, Options) ->

  case lists:member(msg_trace, Options) of
    true  ->
      {ok, CWD }          = file:get_cwd(),
      Dirs                = code:get_path(),

      {ok, Config, _File} = file:path_consult([CWD | Dirs], Filename),

      application:start(crypto),
      application:start(inets),
      application:start(ranch),
      application:start(cowboy),

      application:start(gproc),
      application:start(ssl),
      application:start(timer),

      ssl:start(),
    
      application:start(concurix_runtime),
      gen_server:call(?MODULE, { start_tracer, Config });

    false ->
      { failed }
  end.

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

  
stop() ->
  gen_server:call(?MODULE, stop_tracer).

%%
%% gen_server support
%%

init([]) ->
  {ok, undefined}.

handle_call({start_tracer, Config}, _From, undefined) ->
  %% Contact concurix.com and obtain Keys for S3
  RunInfo   = get_run_info(Config),
  RunId     = proplists:get_value(run_id, RunInfo),

  io:format("Starting tracing with RunId ~p~n", [RunId]),

  %% Allocate shared tables
  Procs     = setup_ets_table(cx_procinfo),
  Links     = setup_ets_table(cx_linkstats),
  SysProf   = setup_ets_table(cx_sysprof),
  ProcLink  = setup_ets_table(cx_proclink),

  State     = #tcstate{runInfo         = RunInfo,

                       processTable    = Procs,
                       linkTable       = Links,
                       sysProfTable    = SysProf,
                       procLinkTable   = ProcLink,
                       traceSupervisor = undefined,
                       sendUpdates     = true},

  {ok, Sup} = concurix_trace_supervisor:start(State),

  fill_initial_tables(State),

  {reply, ok, State#tcstate{traceSupervisor = Sup}};

handle_call({start_tracer, _Config}, _From, State) ->
  io:format("~p:handle_call/3   start_tracer but already running~n", [?MODULE]),
  {reply, ok, State};

handle_call(stop_tracer, _From, undefined) ->
  io:format("~p:handle_call/3   stop_tracer but tracer is not running~n", [?MODULE]),
  {reply, ok, undefined};

handle_call(stop_tracer, _From, State) ->
  concurix_trace_supervisor:stop(State#tcstate.traceSupervisor),
  {reply, ok, undefined}.






%% Make an http call back to concurix for a run id.
%% Assume that the synchronous version of httpc works, although
%% we know it has some intermittent problems under chicago boss.

%% Here is a representative response
%%
%% [ { run_id,    "benchrun-1426"},
%%   { trace_url, "https://concurix_trace_data.s3.amazonaws.com/"},
%%   { fields,    [ { key,             "benchrun-1426"},
%%                  {'AWSAccessKeyId', "<AWS generated string>"},
%%                  {policy,           "<AWS generated string>"},
%%                  {signature,        "<AWS generated string>"}]}]

get_run_info(Config) ->
  { ok, Server } = config_option(Config, master, concurix_server),
  { ok, APIkey } = config_option(Config, master, api_key),

  Url            = "http://" ++ Server ++ "/bench/new_offline_run/" ++ APIkey,
  Reply          = httpc:request(Url),

  case Reply of
    {_, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} -> 
      eval_string(Body);

    _ ->
      {Mega, Secs, Micro} = now(), 
      lists:flatten(io_lib:format("local-~p-~p-~p", [Mega, Secs, Micro]))
  end.


config_option([], _Slot, _Key) ->
  undefined;

config_option([{Slot, SlotConfig} | _Tail], Slot, Key) ->
  config_option(SlotConfig, Key);

config_option([_Head | Tail], Slot, Key) ->
  config_option(Tail, Slot, Key).


config_option([], _Key) ->
  undefined;

config_option([{Key, Value} | _Tail], Key) ->
  { ok, Value};

config_option([_Head | Tail], Key) ->
  config_option(Tail, Key).

eval_string(String) ->
  {ok, Tokens, _} = erl_scan:string(lists:concat([String, "."])),
  {_Status, Term} = erl_parse:parse_term(Tokens),
  Term.

setup_ets_table(T) ->
  case ets:info(T) of
    undefined ->
      ets:new(T, [public]);

    _ -> 
      ets:delete_all_objects(T), 
      T
  end.



handle_cast(_Msg, State) ->
  {noreply, State}.
 

handle_info(_Msg, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  ets:delete(State#tcstate.processTable),
  ets:delete(State#tcstate.linkTable),
  ets:delete(State#tcstate.sysProfTable),
  ets:delete(State#tcstate.procLinkTable),
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.
 
 

%%
%%
%% 

get_current_json(State) ->
  ets:safe_fixtable(State#tcstate.processTable,  true),
  ets:safe_fixtable(State#tcstate.linkTable,     true),
  ets:safe_fixtable(State#tcstate.sysProfTable,  true),
  ets:safe_fixtable(State#tcstate.procLinkTable, true),

  RawProcs       = ets:tab2list(State#tcstate.processTable),
  RawLinks       = ets:tab2list(State#tcstate.linkTable),
  RawSys         = ets:tab2list(State#tcstate.sysProfTable),
  RawProcLink    = ets:tab2list(State#tcstate.procLinkTable),

  {Procs, Links} = validate_tables(RawProcs, RawLinks, State),
 
  ets:safe_fixtable(State#tcstate.sysProfTable,  false),
  ets:safe_fixtable(State#tcstate.linkTable,     false),  
  ets:safe_fixtable(State#tcstate.processTable,  false),
  ets:safe_fixtable(State#tcstate.procLinkTable, false),

  TempProcs      = [ [{name,            pid_to_b(Pid)}, 
                      {module,          term_to_b(M)}, 
                      {function,        term_to_b(F)}, 
                      {arity,           A}, 
                      local_process_info(Pid, reductions),
                      local_process_info(Pid, total_heap_size),
                      term_to_b({service, Service}),
                      {scheduler,       Scheduler},
                      {behaviour,       Behaviour},
                      {application,     pid_to_application(Pid)}] || 
                      {Pid, {M, F, A}, Service, Scheduler, Behaviour} <- Procs ],

  TempLinks      = [ [{source,          pid_to_b(A)}, 
                      {target,          pid_to_b(B)},
                      {value,           C},
                      {words_sent,      D}] || 
                      {{A, B}, C, D} <- Links],

  ProcLinks       = [ [{source,         pid_to_b(A)},
                       {target,         pid_to_b(B)}]
                      || {A, B} <- RawProcLink],

  Schedulers     = [ [{scheduler,       Id}, 
                      {process_create,  Create}, 
                      {quanta_count,    QCount}, 
                      {quanta_time,     QTime}, 
                      {send,            Send}, 
                      {gc,              GC},
                      {true_call_count, True},
                      {tail_call_count, Tail},
                      {return_count,    Return},
                      {process_free,    Free}] ||
                      {Id, {[{concurix, Create, QCount, QTime, Send, GC, True, Tail, Return, Free}], _, _}} <- RawSys ],

  Run_id         = proplists:get_value(run_id, State#tcstate.runInfo),

  Send           = [{version,           2},
                    {run_id,            list_to_binary(Run_id)},
                    {nodes,             TempProcs},
                    {links,             TempLinks},
                    {proclinks,         ProcLinks},
                    {schedulers,        Schedulers}],
 
  lists:flatten(mochijson2:encode([{data, Send}])).


validate_tables(Procs, Links, _State) ->
  Val         = lists:flatten([[A, B] || {{A, B}, _, _}  <- Links]),
  Tempprocs   = lists:usort  ([ A     || {A, _, _, _, _} <- Procs]),
  Templinks   = lists:usort(Val),
  Updateprocs = Templinks -- Tempprocs, 
 
  NewProcs    = update_process_info(Updateprocs, []),
  {Procs ++ NewProcs, Links}. 

update_process_info(Pid) ->
  update_process_info([Pid], []).

update_process_info([],        Acc) ->
  Acc;

update_process_info([Pid | T], Acc) ->
  case local_process_info(Pid, initial_call) of
    {initial_call, MFA} ->
      case MFA of 
        {proc_lib, init_p, _} ->
          {Mod, Fun, Arity} = local_translate_initial_call(Pid);

        {erlang, apply, _} ->
          %% we lost the original MFA, take a best guess from the current function
          case local_process_info(Pid, current_function) of
            {current_function, {Mod, Fun, Arity}} -> 
              ok;

            _ -> 
              %%("got unknown current function results of ~p ~n", [X]),
              {Mod, Fun, Arity} = {erlang, apply, 0}
          end;

        {Mod, Fun, Arity} ->
          ok
      end;

    _ ->
      Mod   = unknown,
      Fun   = Pid,
      Arity = 0
  end,

  Service = mod_to_service(Mod),
  Behave  = mod_to_behaviour(Mod),
  NewAcc  = Acc ++ [{Pid, {Mod, Fun, Arity}, Service, 1, Behave}],

  update_process_info(T, NewAcc).
  


pid_to_b(Pid) ->
  list_to_binary(lists:flatten(io_lib:format("~p", [Pid]))).



term_to_b({Key, Value}) ->
  {Key, term_to_b(Value)};

term_to_b(Val) when is_list(Val) ->
  case io_lib:printable_list(Val) of
    true  ->
      list_to_binary(Val);
    false ->
      [ term_to_b(X) || X <- Val]
  end; 

term_to_b(Term) ->
  list_to_binary(lists:flatten(io_lib:format("~p", [Term]))).
  



%%
%%
%%
 
local_process_info(Pid, reductions) when is_pid(Pid) ->
  case process_info(Pid, reductions) of
    undefined ->
      {reductions, 1};

    X ->
      X
   end;

local_process_info(Pid, initial_call) when is_pid(Pid) ->
  case process_info(Pid, initial_call) of
    undefined ->
      {initial_call, {unknown, unknown, 0}};

    X ->
      X
  end;

local_process_info(Pid, current_function) when is_pid(Pid) ->
  case process_info(Pid, current_function) of
    undefined ->
      {current_function, {unknown, unknown, 0}};

    X ->
      X
  end;

local_process_info(Pid, Key) when is_atom(Pid) ->
  local_process_info(whereis(Pid), Key);

local_process_info(Pid, reductions) when is_port(Pid) ->
  {reductions, 1};

local_process_info(Pid, total_heap_size) when is_port(Pid) ->
  {total_heap_size, 1};

local_process_info(Pid, total_heap_size) when is_pid(Pid) ->
  case process_info(Pid, total_heap_size) of
    undefined ->
      {total_heap_size, 1};

    X ->
      X
  end;

local_process_info(Pid, initial_call) when is_port(Pid) ->
  Info = erlang:port_info(Pid),
  {initial_call, {port, proplists:get_value(name, Info), 0}};

local_process_info({Pid, _X}, Key)     ->
  local_process_info(Pid, Key).

%%
%%
%%

local_translate_initial_call(Pid) when is_pid(Pid) ->
  proc_lib:translate_initial_call(Pid);

local_translate_initial_call(Pid) when is_atom(Pid) ->
  proc_lib:translate_initial_call(whereis(Pid));

local_translate_initial_call({Pid, _X}) ->
  local_translate_initial_call(Pid).
 

%%
%%
%%

mod_to_service(Mod) when is_list(Mod)->
  mod_to_service(list_to_atom(Mod));

mod_to_service(Mod) ->
  case lists:keyfind(Mod, 1, code:all_loaded()) of
    false->
      Mod;

    {_, Path} ->
      path_to_service(Path)
  end.

mod_to_behaviour(unknown) ->
  [<<"undefined">>];
mod_to_behaviour(port) ->
  [<<"port">>];
mod_to_behaviour(Mod) when is_port(Mod) ->
  [<<"port">>];
mod_to_behaviour(Mod) when is_list(Mod) ->
  mod_to_behaviour(list_to_atom(Mod));
mod_to_behaviour(Mod) ->
  Behaviour = case Mod of
      supervisor ->
          %% Module was already translated to supervisor by proc_lib
          [supervisor];
      _ ->
          %% Look for behavior attribute in module information
          case lists:keyfind(attributes, 1, Mod:module_info()) of
              {attributes, AttrList} ->
                  case lists:keyfind(behaviour, 1, AttrList) of
                      {behaviour, Behave} ->
                          Behave;
                      _ ->
                          [undefined]
                  end;
              _ ->
                  [undefined]
          end
  end,
  [atom_to_binary(X, latin1) || X <- Behaviour].
  
pid_to_application(Pid) when is_pid(Pid) ->
  case application:get_application(Pid) of
    undefined -> <<"undefined">>;
    {ok, App} -> atom_to_binary(App, latin1);
    _X -> <<"undefined">>
  end;
pid_to_application(_Pid) ->
  <<"undefined">>.
  
%%
%%
%%

path_to_service(preloaded) ->
  preloaded;

path_to_service(Path) ->
  Tokens = string:tokens(Path, "/"),

  case lists:reverse(Tokens) of 
    [_, "ebin", Service | _] ->
      Service;

    [Service | _] ->
      Service;

    _ ->
      Path
  end.


%%
%% on startup, we want to pre-populate our process and link tables with existing information
%% so that things like the supervision tree are realized properly.

fill_initial_tables(State) ->
  Processes = processes(),
  fill_initial_proctable(State#tcstate.processTable, Processes),
  fill_initial_proclinktable(State#tcstate.procLinkTable, Processes).
  
fill_initial_proctable(Table, Processes) ->
  ProcList = update_process_info(Processes, []),
  lists:foreach(fun(P) -> ets:insert(Table, P) end, ProcList).
  
fill_initial_proclinktable(_Table, []) ->
  ok;
fill_initial_proclinktable(Table, [P | Tail]) ->
  lists:foreach(fun(P2) ->
    ets:insert(Table, {P, P2})
    end,
    get_proc_links(P)
    ),
  fill_initial_proclinktable(Table, Tail).
  
get_proc_links(Proc) ->
    %% Returns a list of linked processes.
    case process_info(Proc, links) of
        {links, Plinks} ->
            [P || P <- Plinks, is_pid(P)];
        _ ->
            []
    end.
