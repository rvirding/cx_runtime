-module(concurix_runtime).

-behaviour(gen_server).

-export([start/2, stop/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([update_process_info/1, mod_to_service/1, local_translate_initial_call/1, get_current_json/1]).

-include("concurix_runtime.hrl").

start(Filename, Options) ->
  case lists:member(msg_trace, Options) of
    true  ->
      {ok, CWD }          = file:get_cwd(),
      Dirs                = code:get_path(),

      {ok, Config, _File} = file:path_consult([CWD | Dirs], Filename),

      gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []);

    false ->
      { failed }
  end.

stop(_Pid) ->
%%  io:format("concurix_runtime:stop/1(~p)~n", [Pid]),
  ok.

%%
%% gen_server support
%%

init([Config]) ->
%%  io:format("concurix_runtime:init/1                                  ~p~n", [self()]),

  io:format("Starting tracing~n"),

  application:start(cowboy),
  application:start(crypto),
  application:start(gproc),
  application:start(inets),
  application:start(ranch),
  application:start(ssl),

  %% Contact concurix.com and obtain Keys for S3
  RunInfo    = get_run_info(Config),

  %% Allocate shared tables
  Procs      = setup_ets_table(cx_procinfo),
  Links      = setup_ets_table(cx_linkstats),
  SysProf    = setup_ets_table(cx_sysprof),

  State      = #tcstate{runInfo         = RunInfo,

                        processTable    = Procs,
                        linkTable       = Links,
                        sysProfTable    = SysProf,
                        traceSupervisor = undefined},

  {ok, Sup } = concurix_trace_supervisor:start(State),

  {ok, State#tcstate{traceSupervisor = Sup}}.
 
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
      lists:flatten(io_lib:format("local-~p-~p-~p",[Mega, Secs, Micro]))
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

handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
handle_info({websocket_init, WebSocketPid}, State) ->
  io:format("concurix_runtime:handle_info/2 ~p~n", [WebSocketPid]),
  {noreply, State};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  ets:delete(State#tcstate.processTable),
  ets:delete(State#tcstate.linkTable),
  ets:delete(State#tcstate.sysProfTable),
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.
 
 

%%
%%
%% 

get_current_json(State) ->
  ets:safe_fixtable(State#tcstate.processTable, true),
  ets:safe_fixtable(State#tcstate.linkTable,    true),
  ets:safe_fixtable(State#tcstate.sysProfTable, true),

  RawProcs       = ets:tab2list(State#tcstate.processTable),
  RawLinks       = ets:tab2list(State#tcstate.linkTable),
  RawSys         = ets:tab2list(State#tcstate.sysProfTable),

  {Procs, Links} = validate_tables(RawProcs, RawLinks, State),
 
  ets:safe_fixtable(State#tcstate.sysProfTable, false),
  ets:safe_fixtable(State#tcstate.linkTable,    false),  
  ets:safe_fixtable(State#tcstate.processTable, false),

  TempProcs      = [ [{name,            pid_to_b(Pid)}, 
                      {module,          term_to_b(M)}, 
                      {function,        term_to_b(F)}, 
                      {arity,           A}, 
                      local_process_info(Pid, reductions),
                      local_process_info(Pid, total_heap_size),
                      term_to_b({service, Service}),
                      {scheduler,       Scheduler}] || 
                      {Pid, {M, F, A}, Service, Scheduler} <- Procs ],

  TempLinks      = [ [{source,          pid_to_b(A)}, 
                      {target,          pid_to_b(B)},
                      {value,           C}] || 
                      {{A, B}, C} <- Links],

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

  Send           = [{version,           1},
                    {run_id,            list_to_binary(Run_id)},
                    {nodes,             TempProcs},
                    {links,             TempLinks},
                    {schedulers,        Schedulers}],
 
  lists:flatten(mochijson2:encode([{data, Send}])).




validate_tables(Procs, Links, _State) ->
  Val         = lists:flatten([[A, B] || {{A, B}, _}  <- Links]),
  Tempprocs   = lists:usort  ([ A     || {A, _, _, _} <- Procs]),
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
  NewAcc  = Acc ++ [{Pid, {Mod, Fun, Arity}, Service}],

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

 
