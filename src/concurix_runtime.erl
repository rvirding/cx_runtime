-module(concurix_runtime).

-behaviour(gen_server).

-export([start/2, stop/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([handle_system_profile/1, send_summary/1, send_snapshot/1]).

-record(tcstate, {processTable, linkTable, sysProfTable, timerTable, runInfo, sysProfPid, webSocketPid}).

-define(TIMER_INTERVAL_VIZ,        2 * 1000).    %% Update VIZ every 2 seconds
-define(TIMER_INTERVAL_S3,    2 * 60 * 1000).    %% Update S3  every 2 minutes

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
%% Children needed to
%%
%%   1) Run the standard tracer
%%   2) Run the system profiler
%%
%%   3) Communicate with Browser over an open websocket
%%   4) Maintain a long running update to S3
%%

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
  Dispatch = cowboy_router:compile([{'_',       [    {"/",  concurix_trace_socket_handler, [self()]} ] } ]),

  %%                Name, NbAcceptors, TransOpts,      ProtoOpts
  cowboy:start_http(http, 100,         [{port, 6788}], [{env, [{dispatch, Dispatch}]}]),

  State    = start_trace_client(Config),

  {ok, State}.
 
handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
handle_info({websocket_init, WebSocketPid}, StateOld) ->
%%  io:format("concurix_runtime:handle_info/2 ~p~n", [WebSocketPid]),
%%  io:format("  StateOld: ~p~n", [StateOld]),

  StateNew = StateOld#tcstate{webSocketPid = WebSocketPid},

%%  io:format("  StateNew: ~p~n", [StateNew]),
  {noreply, StateNew};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  dbg:stop_clear(),
  cleanup_timers(),

  ets:delete(State#tcstate.processTable),
  ets:delete(State#tcstate.linkTable),
  ets:delete(State#tcstate.sysProfTable),
  ets:delete(State#tcstate.timerTable),
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

  Procs      = setup_ets_table(cx_procinfo),
  Links      = setup_ets_table(cx_linkstats),
  SysProf    = setup_ets_table(cx_sysprof),
  Timers     = setup_ets_table(cx_timers),

  RunInfo    = get_run_info(Config),

  SysProfPid = spawn_link(?MODULE, handle_system_profile, [SysProf]),
  erlang:system_profile(SysProfPid, [concurix]),

  State      = #tcstate{processTable = Procs,
                        linkTable    = Links,
                        sysProfTable = SysProf,
                        timerTable   = Timers,
                        runInfo      = RunInfo,
                        sysProfPid   = SysProfPid,
                        webSocketPid = undefined},

  %% now turn on the tracing
  {ok, Pid}  = dbg:tracer(process, { fun(A, B) -> handle_trace_message(A, B) end, State }),
  erlang:link(Pid),

  dbg:p(all, [s, p]),
 
  %% this is a workaround for dbg:p not knowing the hidden scheduler_id flag. :-)
  %% basically we grab the tracer setup in dbg and then add a few more flags
  T          = erlang:trace_info(self(), tracer),

  erlang:trace(all, true, [procs, send, running, scheduler_id, T]),

  {ok, T1}   = timer:apply_interval(?TIMER_INTERVAL_VIZ, ?MODULE, send_summary,  [State]),
  {ok, T2}   = timer:apply_interval(?TIMER_INTERVAL_S3,  ?MODULE, send_snapshot, [State]),

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
%% We assume that the synchronous version of httpc works, although
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



%%
%% The Concurix system profiler
%%
%% Each scheduler sends a message at a standard interval, currently every 2 seconds, 
%% that provides a snapshot of the activity that occured during the most recent interval (window).
%% 
%% The Stats element is the tuple
%%     'concurix',
%%     number of processes created
%%     number of quanta executed
%%     total quanta time (us)
%%     number of messages send
%%     number of GCs performed
%%     number of true calls performed
%%     number of tail calls performed
%%     number of returns executed
%%     number of processes that exited
%%
%% The message also indicates the start/end time for the sample
%%
 
handle_system_profile(Proftable) ->
  receive
    { profile, concurix, SchedulerId,  SchedulerStats, WindowStart, WindowStop } ->
      ets:insert(Proftable, {SchedulerId, {SchedulerStats, WindowStart, WindowStop}}),
      handle_system_profile(Proftable);

    Other ->
      io:format("OTHER:    ~p~n", [Other]),
      handle_system_profile(Proftable)
  end.
 


%%
%% The standard trace handler
%%
 
%%
%% Handle process creation and destruction
%%
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

  ets:insert(State#tcstate.processTable, Key),

  %% also include a link from the creator process to the created.
  update_proc_table(Creator, State),
  ets:insert(State#tcstate.linkTable, {{Creator, Pid}, 1}),
  State;

handle_trace_message({trace, Pid, exit, _Reason}, State) ->
  ets:safe_fixtable(State#tcstate.processTable, true),
  ets:safe_fixtable(State#tcstate.linkTable,    true), 

  ets:select_delete(State#tcstate.linkTable,    [ { {{'_', Pid}, '_'}, [], [true]}, 
                                                  { {{Pid, '_'}, '_'}, [], [true] } ]),
  ets:select_delete(State#tcstate.processTable, [ { {Pid, '_', '_', '_'}, [], [true]}]),

  ets:safe_fixtable(State#tcstate.linkTable,    false),  
  ets:safe_fixtable(State#tcstate.processTable, false), 

  State;


%%
%% These messages are sent when a Process is started/stopped on a given scheduler
%%

handle_trace_message({trace, Pid, in,  Scheduler, _MFA}, State) ->
  update_proc_scheduler(Pid, Scheduler, State),
  State;

handle_trace_message({trace, Pid, out, Scheduler, _MFA}, State) ->
  update_proc_scheduler(Pid, Scheduler, State),
  State;


%%
%% Track messages sent
%%
handle_trace_message({trace, Sender, send, _Data, Recipient}, State) ->
  update_proc_table(Sender,    State),
  update_proc_table(Recipient, State),

  case ets:lookup(State#tcstate.linkTable, {Sender, Recipient}) of
    [] ->
      ets:insert(State#tcstate.linkTable, {{Sender, Recipient}, 1});

    _ ->
      ets:update_counter(State#tcstate.linkTable, {Sender, Recipient}, 1)
  end, 

  State;


%%
%% These messages are ignored
%%
handle_trace_message({trace, _Pid, getting_linked,   _Pid2}, State) ->
  State;

handle_trace_message({trace, _Pid, getting_unlinked, _Pid2}, State) ->
  State;

handle_trace_message({trace, _Pid, link,             _Pid2}, State) ->
  State;

handle_trace_message({trace, _Pid, unlink,           _Pid2}, State) ->
  State;

handle_trace_message({trace, _Pid, register,         _Srv},  State) ->
  State;

handle_trace_message(Msg,                                    State) ->
  io:format("~p:handle_trace_message/2.  Unsupported msg = ~p ~n", [?MODULE, Msg]),
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
 
update_proc_table(Pid, State) ->
  case ets:lookup(State#tcstate.processTable, Pid) of
    [] ->
      [{Pid, {Mod, Fun, Arity}, Service}] = update_process_info(Pid),
      ets:insert(State#tcstate.processTable, {Pid, {Mod, Fun, Arity}, Service, 0});

    _ ->
      ok
  end.

update_proc_scheduler(Pid, Scheduler, State) ->
  case ets:lookup(State#tcstate.processTable, Pid) of 
    [] ->
      %% we don't have it yet, wait until we get the create message
      ok;

    [{Pid, {Mod, Fun, Arity}, Service, _OldScheduler}] ->
      ets:insert(State#tcstate.processTable, {Pid, {Mod, Fun, Arity}, Service, Scheduler});

    X ->
      io:format("yikes, corrupt proc table ~p ~n", [X])
  end.


%%
%%
%% 

send_summary(State)->
%%  io:format("concurix_runtime:send_summary/1~n"),

  case gproc:lookup_pids({p, l, "benchrun_tracing"}) of
    [] ->
      ok;

    [Pid] ->
%%    io:format("  PID:   ~p~n", [Pid]),
%%    io:format("  Sock:  ~p~n", [State#tcstate.webSocketPid]),
      Pid ! { trace, get_current_json(State) };

    _  ->
      ok
  end.

%%
%%
%% 

send_snapshot(State) ->
  Url                 = proplists:get_value(trace_url, State#tcstate.runInfo),
  Fields              = snapshot_fields(State),
  Data                = list_to_binary(get_current_json(State)),

  Request             = erlcloud_s3:make_post_http_request(Url, Fields, Data),

  httpc:request(post, Request, [{timeout, 60000}], [{sync, true}]).

snapshot_fields(State) ->
  Run_id              = proplists:get_value(run_id, State#tcstate.runInfo),
  Fields              = proplists:get_value(fields, State#tcstate.runInfo),

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
  ets:safe_fixtable(State#tcstate.processTable, true),
  ets:safe_fixtable(State#tcstate.linkTable,    true),
  ets:safe_fixtable(State#tcstate.sysProfTable, true),

  RawProcs       = ets:tab2list(State#tcstate.processTable),
  RawLinks       = ets:tab2list(State#tcstate.linkTable),
  RawSys         = ets:tab2list(State#tcstate.sysProfTable),

  {Procs, Links} = validate_tables(RawProcs, RawLinks, State),
 
  ets:safe_fixtable(State#tcstate.linkTable,    false),  
  ets:safe_fixtable(State#tcstate.processTable, false),
  ets:safe_fixtable(State#tcstate.sysProfTable, false),

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

  Run_id         = proplists:get_value(run_id, State#tcstate.runInfo),

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
 
