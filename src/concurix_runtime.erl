-module(concurix_runtime).

-behaviour(gen_server).

-export([start/2, stop/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([handle_system_profile/1, send_summary/1, send_snapshot/1]).

-record(tcstate, {proctable, linktable, sptable, timertable, runinfo, sp_pid}).

%% Send an update to the visualizer every two seconds
%% Send a  snapshot to S3           every two minutes

-define(TIMER_INTERVAL_VIZ,        2 * 1000).
-define(TIMER_INTERVAL_S3,    2 * 60 * 1000).

start(Filename, Options) ->
  case lists:member(msg_trace, Options) of
    true  ->
      {ok, CWD }          = file:get_cwd(),
      Dirs                = code:get_path(),

      {ok, Config, _File} = file:path_consult([CWD | Dirs], Filename),

      gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []);

    false ->
      ok
  end.

stop() ->
  ok.

%%
%% gen_server support
%%

init([Config]) ->
  application:start(cowboy),
  application:start(crypto),
  application:start(gproc),
  application:start(inets),
  application:start(ranch),
  application:start(ssl),

  %%                                {HostMatch, list({Path, Handler,                       Opts})}
  Dispatch = cowboy_router:compile([{'_',       [    {"/",  concurix_trace_socket_handler, []} ]}]),

  %%                Name, NbAcceptors, TransOpts,      ProtoOpts
  cowboy:start_http(http, 100,         [{port, 6788}], [{env, [{dispatch, Dispatch}]}]),

  State    = start_trace_client(Config),

  {ok, State}.
 
handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  dbg:stop_clear(),
  cleanup_timers(),

  ets:delete(State#tcstate.proctable),
  ets:delete(State#tcstate.linktable),
  ets:delete(State#tcstate.sptable),
  ets:delete(State#tcstate.timertable),
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.
 
 
%%
%% do the real work of starting a run.
%%
start_trace_client(Config) ->
  io:format("Starting tracing~n"),

  %% Ensure there isn't any state from a previous run
  dbg:stop_clear(),
  dbg:start(),

  cleanup_timers(),

  Stats     = setup_ets_table(cx_linkstats),
  Procs     = setup_ets_table(cx_procinfo),
  Prof      = setup_ets_table(cx_sysprof),
  Timers    = setup_ets_table(cx_timers),

  RunInfo   = get_run_info(Config),

  Sp_pid    = spawn_link(?MODULE, handle_system_profile, [Prof]),
  erlang:system_profile(Sp_pid, [concurix]),

  State     = #tcstate{proctable  = Procs,
                       linktable  = Stats,
                       sptable    = Prof,
                       timertable = Timers,
                       runinfo    = RunInfo,
                       sp_pid     = Sp_pid},

  %% now turn on the tracing
  {ok, Pid} = dbg:tracer(process, { fun(A, B) -> handle_trace_message(A, B) end, State }),
  erlang:link(Pid),

  dbg:p(all, [s, p]),
 
  %% this is a workaround for dbg:p not knowing the hidden scheduler_id flag. :-)
  %% basically we grab the tracer setup in dbg and then add a few more flags
  T         = erlang:trace_info(self(), tracer),

  erlang:trace(all, true, [procs, send, running, scheduler_id, T]),

  {ok, T1}  = timer:apply_interval(?TIMER_INTERVAL_VIZ, ?MODULE, send_summary,  [State]),
  {ok, T2}  = timer:apply_interval(?TIMER_INTERVAL_S3,  ?MODULE, send_snapshot, [State]),

  ets:insert(Timers, {realtime_timer, T1}),
  ets:insert(Timers, {s3_timer,       T2}),
 
  State.
 
cleanup_timers() ->
  case ets:info(cx_timers) of
    undefined -> 
      ok;

    _ -> 
     List = ets:tab2list(cx_timers),
     [ timer:cancel(T) || {_Y, T } <- List]
  end.

setup_ets_table(T) ->
  case ets:info(T) of
    undefined ->
      ets:new(T, [public, named_table]);

    _ -> 
      ets:delete_all_objects(T), 
      T
  end.

%% Make an http call back to concurix for our run id.
%% We assume that the synchronous version of httpc works, though
%% we know it has some intermittent problems under chicago boss.

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



%%
%%
%%
 
handle_system_profile(Proftable) ->
  receive
    { profile, concurix, Id,  Summary, TimestampStart, TimestampStop } ->
      ets:insert(Proftable, {Id, {Summary, TimestampStart, TimestampStop}}),
      handle_system_profile(Proftable);

    Other ->
      io:format("OTHER:    ~p~n", [Other]),
      handle_system_profile(Proftable)
  end.
 


%%
%%
%%
 
handle_trace_message({trace, Sender, send, _Data, Recipient}, State) ->
  update_proc_table([Sender, Recipient], State, []),

  case ets:lookup(State#tcstate.linktable, {Sender, Recipient}) of
    [] ->
      ets:insert(State#tcstate.linktable, {{Sender, Recipient}, 1});

    _ ->
      ets:update_counter(State#tcstate.linktable, {Sender, Recipient}, 1)
  end, 

  State;

handle_trace_message({trace, Pid, exit, _Reason}, State) ->
  ets:safe_fixtable(State#tcstate.proctable, true),
  ets:safe_fixtable(State#tcstate.linktable, true), 

  ets:select_delete(State#tcstate.linktable, [ { {{'_', Pid},'_'}, [], [true]}, { {{Pid, '_'}, '_'}, [], [true] } ]),
  ets:select_delete(State#tcstate.proctable, [ { {Pid, '_', '_', '_'}, [], [true]}]),

  ets:safe_fixtable(State#tcstate.linktable, false),  
  ets:safe_fixtable(State#tcstate.proctable, false), 

  State;

handle_trace_message({trace, Creator, spawn, Pid, Data}, State) ->
  case Data of 
    {proc_lib, init_p, _ProcInfo} ->
      {Mod, Fun, Arity} = local_translate_initial_call(Pid),
      ok;

    {erlang, apply, [TempFun, _Args]} ->
      {Mod, Fun, Arity} = decode_anon_fun(TempFun);

    {Mod, Fun, Args} ->
      Arity = length(Args),
      ok;

    X ->
      %%io:format("got unknown spawn of ~p ~n", [X]),
      Mod   = unknown,
      Fun   = X,
      Arity = 0
  end,

  Service = mod_to_service(Mod),
  Key     = {Pid, {Mod, Fun, Arity}, Service, 0},

  ets:insert(State#tcstate.proctable, Key),

  %% also include a link from the creator process to the created.
  update_proc_table([Creator], State, []),
  ets:insert(State#tcstate.linktable, {{Creator, Pid}, 1}),
  State;

handle_trace_message({trace, Pid, in, Scheduler, _MFA}, State) ->
  update_proc_scheduler(Pid, Scheduler, State),
  State;

handle_trace_message({trace, Pid, out, Scheduler, _MFA}, State) ->
  update_proc_scheduler(Pid, Scheduler, State),
  State;

handle_trace_message({trace, _Pid, getting_unlinked, _Pid2}, State)->
  State;

handle_trace_message({trace, _Pid, unlink, _Pid2 }, State) ->
  State;

handle_trace_message({trace, _Pid, getting_linked, _Pid2}, State) ->
  State;

handle_trace_message({trace, _Pid, link, _Pid2}, State) ->
  State;

handle_trace_message(_Msg, State) ->
  %%io:format("msg = ~p ~n", [Msg]),
  State.

decode_anon_fun(Fun) ->
  Str = lists:flatten(io_lib:format("~p", [Fun])),

  case string:tokens(Str, "<") of
    ["#Fun", Name] ->
      [Mod | _] = string:tokens(Name, ".");

    _ ->
      Mod = "anon_function"
  end,

  {Mod, Str, 0}.
 
update_proc_table([], _State, Acc) ->
  Acc;

update_proc_table([Pid | Tail], State, Acc) ->
  case ets:lookup(State#tcstate.proctable, Pid) of
    [] ->
      [{Pid, {Mod, Fun, Arity}, Service}] = update_process_info(Pid),
      NewAcc = Acc ++ [{Pid, {Mod, Fun, Arity}, Service}],
      ets:insert(State#tcstate.proctable, {Pid, {Mod, Fun, Arity}, Service, 0});

    _ ->
      NewAcc = Acc
  end,

  update_proc_table(Tail, State, NewAcc).

update_proc_scheduler(Pid, Scheduler, State) ->
  case ets:lookup(State#tcstate.proctable, Pid) of 
    [] ->
      %% we don't have it yet, wait until we get the create message
      ok;

    [{Pid, {Mod, Fun, Arity}, Service, _OldScheduler}] ->
      ets:insert(State#tcstate.proctable, {Pid, {Mod, Fun, Arity}, Service, Scheduler});

    X ->
      io:format("yikes, corrupt proc table ~p ~n", [X])
  end.


%%
%%
%% 

send_summary(State)->
  Json = get_current_json(State),

  case gproc:lookup_pids({p, l, "benchrun_tracing"}) of
    [] ->
      ok;

    _  ->
      gproc:send({p, l, "benchrun_tracing"}, {trace, Json})
  end.

%%
%%
%% 

send_snapshot(State) ->
  Url     = proplists:get_value(trace_url, State#tcstate.runinfo),
  Fields  = snapshot_fields(State),
  Data    = list_to_binary(get_current_json(State)),

  Request = erlcloud_s3:make_post_http_request(Url, Fields, Data),

  httpc:request(post, Request, [{timeout, 60000}], [{sync, true}]).

snapshot_fields(State) ->
  Run_id              = proplists:get_value(run_id, State#tcstate.runinfo),
  Fields              = proplists:get_value(fields, State#tcstate.runinfo),

  {Mega, Secs, Micro} = now(),
  KeyString           = io_lib:format("json_realtime_trace_snapshot.~p.~p-~p-~p",[node(), Mega, Secs, Micro]),
  Key                 = lists:flatten(KeyString),

  case proplists:is_defined(key, Fields) of
    true  ->
      Temp = proplists:delete(key, Fields);

    false -> 
      Temp = Fields
  end,

  Temp ++ [{key, Run_id ++ "/" ++ Key}].

%%
%%
%% 

get_current_json(State) ->
  ets:safe_fixtable(State#tcstate.proctable, true),
  ets:safe_fixtable(State#tcstate.linktable, true),
  ets:safe_fixtable(State#tcstate.sptable,   true),

  RawProcs       = ets:tab2list(State#tcstate.proctable),
  RawLinks       = ets:tab2list(State#tcstate.linktable),
  RawSys         = ets:tab2list(State#tcstate.sptable),

  {Procs, Links} = validate_tables(RawProcs, RawLinks, State),
 
  ets:safe_fixtable(State#tcstate.linktable, false),  
  ets:safe_fixtable(State#tcstate.proctable, false),
  ets:safe_fixtable(State#tcstate.sptable,   false),

  TempProcs      = [ [{name,     pid_to_b(Pid)}, 
                      {module,   term_to_b(M)}, 
                      {function, term_to_b(F)}, 
                      {arity,    A}, 
                      local_process_info(Pid, reductions),
                      local_process_info(Pid, total_heap_size),
                      term_to_b({service, Service}),
                      {scheduler, Scheduler}] || 
                      {Pid, {M, F, A}, Service, Scheduler} <- Procs ],

  TempLinks      = [ [{source, pid_to_b(A)}, 
                      {target, pid_to_b(B)},
                      {value, C}] || 
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

  Run_id         = proplists:get_value(run_id, State#tcstate.runinfo),

  Send           = [{version,    1},
                    {run_id,     list_to_binary(Run_id)},
                    {nodes,      TempProcs},
                    {links,      TempLinks},
                    {schedulers, Schedulers}],
 
  lists:flatten(mochijson2:encode([{data, Send}])).

validate_tables(Procs, Links, _State) ->
  Val         = lists:flatten([[A, B] || {{A, B}, _} <- Links]),
  Tempprocs   = lists:usort([ A || {A, _, _, _} <-Procs ]),
  Templinks   = lists:usort(Val),
  Updateprocs = Templinks -- Tempprocs, 
 
  NewProcs    = update_process_info(Updateprocs, []),
  {Procs ++ NewProcs, Links}. 

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
%%
%%

update_process_info(Pid) ->
  update_process_info([Pid], []).

update_process_info([], Acc) ->
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
 
