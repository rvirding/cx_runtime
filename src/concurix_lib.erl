%% %CopyrightBegin%
%%
%% Copyright Concurix Corporation 2012-2013. All Rights Reserved.
%%
%% The contents of this file are subject to the Concurix Terms of Service:
%% http://www.concurix.com/main/tos_main
%%
%% The Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. 
%%
%% %CopyrightEnd%
%%
%% This file contains both the top level API's as well as the root gen_server for the Concurix Runtime
%%

-module(concurix_lib).

-export([update_process_info/1,
         update_process_info/2,
         mod_to_service/1,
         local_translate_initial_call/1,
         get_current_json/1,
         mod_to_behaviour/1,
         get_default_json/1,
         merge_run_info/2,
         careful_process_info/2,
         get_json_for_proxy/1]).

-record(last_node, {pid, total_heap_size}).

-include("concurix_runtime.hrl").

%%%=============================================================================
%%% External functions
%%%=============================================================================

%%
%% process_info is defined to throw an exception if Pid is not local
%%
%% This version verifies that the PID is for the current node
%% The callers to this function already have business logic for 'undefined'
%%
careful_process_info(Pid, Item) when node(Pid) =:= node() ->
  process_info(Pid, Item);

careful_process_info(_Pid, _Item) ->
  undefined.

local_translate_initial_call(Pid) when is_pid(Pid) ->
  proc_lib:translate_initial_call(Pid);

local_translate_initial_call(Pid) when is_atom(Pid) ->
  proc_lib:translate_initial_call(whereis(Pid));

local_translate_initial_call({Pid, _X}) ->
  local_translate_initial_call(Pid).

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

            Other -> 
              %%("got unknown current function results of ~p ~n", [X]),
              {Mod, Fun, Arity} = {erlang, apply, 0}
          end;

        {Mod, Fun, Arity} ->
          ok
      end;

    OtherResult ->
      Mod   = unknown,
      Fun   = Pid,
      Arity = 0
  end,

  Service = mod_to_service(Mod),
  Behave  = mod_to_behaviour(Mod),
  NewAcc  = Acc ++ [{Pid, {Mod, Fun, Arity}, Service, 1, Behave}],

  update_process_info(T, NewAcc).

get_current_json(#tcstate{traceMf = TraceMF} = State) ->
  {Module, Function} = TraceMF,
  Module:Function(State).

get_default_json(State) ->
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

  CallTotals = lists:foldl(fun ({{Source, _Target}, NumCalls, _WordsSent, _Start}, Acc) ->
                                   dict:update_counter(Source, NumCalls, Acc)
                           end,
                           dict:new(),
                           Links),

  NumCalls = fun (Pid) ->
                     case dict:find(Pid, CallTotals) of
                         {ok, Value} -> Value;
                         error -> 0
                     end
             end,

  TempProcs      = [ [{id,              pid_to_b(Pid)},
                      {pid,             ospid_to_b()},
                      {name,            pid_to_name(Pid)},
                      {module,          [{top, term_to_b(M)}, % TODO is this correct?
                                         {requireId, term_to_b(M)},
                                         {id, mod_to_id(M)}]},
                      {fun_name,        term_to_b(F)},
                      {arity,           A},
                      local_process_info(Pid, reductions),
                      local_process_info(Pid, message_queue_len),
                      term_to_b({service, Service}),
                      {scheduler,       Scheduler},
                      {behaviour,       Behaviour},
                      {application,     pid_to_application(Pid)},
                      {num_calls,       NumCalls(Pid)},
                      {duration,        1000}, % TODO fixme
                      {child_duration,  100} % TODO this isn't even in the spec but is required for the dashboard to work
                     ] ++ delta_info(State#tcstate.lastNodes, Pid)
                     ||
                      {Pid, {M, F, A}, Service, Scheduler, Behaviour} <- Procs ],

  TempLinks      = [ [{source,          pid_to_name(A)},
                      {target,          pid_to_name(B)},
                      {type,            <<"message">>},
                      {total_delay,     100}, % TODO fixme
                      {start,           Start},
                      {num_calls,       C},
                      {words_sent,      D}] ||
                      {{A, B}, C, D, Start} <- Links],

  ProcLinks       = [ [{source,         pid_to_name(A)},
                       {target,         pid_to_name(B)}]
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

  Run_id         = binary_to_list(proplists:get_value(<<"run_id">>, State#tcstate.runInfo)),


  case os:type() of
      {unix, linux} ->
        {ok, LoadAvg} = concurix_cpu_info:get_load_avg(),
        {ok, CpuTimes} = concurix_cpu_info:get_cpu_times(),
        {ok, CpuInfos} = concurix_cpu_info:get_cpu_info(),
        Cpus = [[{times, proplists:get_value(proplists:get_value(id, CpuInfo), CpuTimes)} | CpuInfo] || CpuInfo <- CpuInfos];
      _ ->
        LoadAvg = [],
        Cpus = []
  end,

  Send           = [{method, <<"Concurix.traces">>},
                    {result, 
                      [{type,              <<"erlang">>},
                      {version,           <<"0.1.4">>},
                      {run_id,            list_to_binary(Run_id)},
                      {timestamp,         now_seconds()},
                      {load_avg,          LoadAvg},
                      {cpus,              Cpus},

                      {data,              [{nodes,             TempProcs},
                                           {links,             TempLinks},
                                           {proclinks,         ProcLinks},
                                           {schedulers,        Schedulers}]}]}],

  cx_jsx_eep0018:term_to_json(Send, []).

get_json_for_proxy(State) ->
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

  CallTotals = lists:foldl(fun ({{Source, _Target}, NumCalls, _WordsSent, _Start}, Acc) ->
                                   dict:update_counter(Source, NumCalls, Acc)
                           end,
                           dict:new(),
                           Links),

  NumCalls = fun (Pid) ->
                     case dict:find(Pid, CallTotals) of
                         {ok, Value} -> Value;
                         error -> 0
                     end
             end,

  TempProcs      = [ [{id,              get_pid_app_name(Pid)},
                      {proxyId,         <<"1823a94bdcd7ef6f61772e46c0610942">>},
                      {pid,             ospid_to_b()},
                      {name,            get_pid_app_name(Pid)},
                      {module,          [{top, term_to_b(M)}, % TODO is this correct?
                                         {requireId, term_to_b(M)},
                                         {id, mod_to_id(M)}]},
                      {fun_name,        term_to_b(F)},
                      {line,            <<"0">>},
                      {start,           <<"391216792868">>},
                      {next_level,      <<"NaN">>},
                      {merge, [
                        {'Function', <<"merge">>},
                        {length, <<"1">>},
                        {name, <<"merge">>},
                        {arguments, <<"null">>},
                        {caller, <<"null">>},
                        {prototype, <<"null">>}
                      ]},
                      {arity,           A},
                      local_process_info(Pid, reductions),
                      local_process_info(Pid, message_queue_len),
                      term_to_b({service, Service}),
                      {scheduler,       Scheduler},
                      {behaviour,       Behaviour},
                      {application,     pid_to_application(Pid)},
                      {num_calls,       NumCalls(Pid)},
                      {duration,        1000}, % TODO fixme
                      {child_duration,  100} % TODO this isn't even in the spec but is required for the dashboard to work
                     ] ++ delta_info(State#tcstate.lastNodes, Pid)
                     ||
                      {Pid, {M, F, A}, Service, Scheduler, Behaviour} <- Procs ],

  TempLinks      = [ [{source,          pid_to_name(A)},
                      {target,          pid_to_name(B)},
                      {type,            <<"message">>},
                      {total_delay,     100}, % TODO fixme
                      {start,           Start},
                      {num_calls,       C},
                      {words_sent,      D}] ||
                      {{A, B}, C, D, Start} <- Links],

  ProcLinks       = [ [{source,         pid_to_name(A)},
                       {target,         pid_to_name(B)}]
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

  Run_id         = binary_to_list(proplists:get_value(<<"run_id">>, State#tcstate.runInfo)),


  case os:type() of
      {unix, linux} ->
        {ok, LoadAvg} = concurix_cpu_info:get_load_avg(),
        {ok, CpuTimes} = concurix_cpu_info:get_cpu_times(),
        {ok, CpuInfos} = concurix_cpu_info:get_cpu_info(),
        Cpus = [[{times, proplists:get_value(proplists:get_value(id, CpuInfo), CpuTimes)} | CpuInfo] || CpuInfo <- CpuInfos];
      _ ->
        LoadAvg = [],
        Cpus = []
  end,

  Send           =   [{type,              <<"erlang">>},
                      {version,           <<"0.1.4">>},

                      {tracing_interval,   ?TIMER_INTERVAL_VIZ},
                      {hostname,           get_hostname()},
                      {pid,                11088},

                      {load_avg, [39.3, 38.2, 40.8]},

                      {cpus, [

                      ]},

                      {process_info, [
                        {memory,  [
                          {rss, 15839232}, 
                          {heapTotal, 10324992}, 
                          {heapUsed, 4810784}
                        ]},

                        {uptime, 2},
                        {active_requests, 0},
                        {active_handles, 2},
                        {versions, [
                          {http_parser, <<"1.0">>},
                          {node, <<"0.10.25">>},
                          {v8, <<"3.14.5.9">>},
                          {ares, <<"1.9.0-DEV">>},
                          {uv, <<"0.10.23">>},
                          {zlib, <<"1.2.3">>},
                          {modules, <<"11">>},
                          {openssl, <<"1.0.1e">>}
                        ]},
                        {environment, <<"default">>}
                      ]},

                      {system_info, [
                        {freemem, 670539776},
                        {totalmem, 8589934592},
                        {arch, <<"x64">>},
                        {platform, <<"darwin">>},
                        {uptime, 917380.0}
                      ]},

                      {timestamp,         now_seconds()},

                      {data,              [{nodes,             TempProcs},
                                           {links,             TempLinks},
                                           {proclinks,         ProcLinks},
                                           {schedulers,        Schedulers}]}],

  cx_jsx_eep0018:term_to_json(Send, []).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

pid_to_name(Pid) ->
  << (ospid_to_b())/binary, ":", (pid_to_b(Pid))/binary >>.

ospid_to_b() ->
  list_to_binary(os:getpid()).

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

local_process_info(Pid, reductions) when is_pid(Pid) ->
  case careful_process_info(Pid, reductions) of
    undefined ->
      {reductions, 1};

    X ->
      X
   end;

local_process_info(Pid, initial_call) when is_pid(Pid) ->
  case careful_process_info(Pid, initial_call) of
    undefined ->
      {initial_call, {unknown, unknown, 0}};

    X ->
      X
  end;

local_process_info(Pid, current_function) when is_pid(Pid) ->
  case careful_process_info(Pid, current_function) of
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
  case careful_process_info(Pid, total_heap_size) of
    undefined ->
      {total_heap_size, 1};

    X ->
      X
  end;

local_process_info(Pid, initial_call) when is_port(Pid) ->
  Info = erlang:port_info(Pid),
  {initial_call, {port, proplists:get_value(name, Info), 0}};
  
local_process_info(Pid, message_queue_len) when is_port(Pid) ->
  {message_queue_len, 0};

local_process_info(Pid, message_queue_len) when is_pid(Pid) ->
  case careful_process_info(Pid, message_queue_len) of
    undefined ->
      {message_queue_len, 0};
    X ->
      X
  end;

local_process_info({Pid, _X}, Key)     ->
  local_process_info(Pid, Key).

mod_to_id(Mod) when is_list(Mod) ->
    mod_to_id(list_to_atom(Mod)); % TODO trackdown the source of these string module names
mod_to_id(Mod) when is_atom(Mod) ->
    case code:is_loaded(Mod) of
        {file, Path} when is_list(Path) ->
            list_to_binary(Path);
        _ ->
            list_to_binary(atom_to_list(Mod))
    end.

pid_to_application(Pid) when is_pid(Pid), node(Pid) =:= node() ->
  case application:get_application(Pid) of
    undefined -> <<"undefined">>;
    {ok, App} -> atom_to_binary(App, latin1)
  end;

pid_to_application(_Pid) ->
  <<"undefined">>.

delta_info(LastNodes, Pid) ->
    {total_heap_size, TotalHeapSize} = local_process_info(Pid, total_heap_size),
    MemDelta =
        case ets:lookup(LastNodes, Pid) of
            [] ->
                TotalHeapSize;
            [#last_node{total_heap_size=LastTotalHeapSize}] ->
                 TotalHeapSize - LastTotalHeapSize
        end,
    ets:insert(LastNodes, #last_node{pid=Pid, total_heap_size=TotalHeapSize}),
    [{total_heap_size, TotalHeapSize},
     {mem_delta, MemDelta}].

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

now_seconds() ->
    {Mega, Secs, _}= now(),
    Mega*1000000 + Secs.

-spec get_pid_app_name(Pid :: pid()) -> binary().
get_pid_app_name(Pid) ->
  case (catch application:get_application(Pid)) of
    {ok, Application} ->
      list_to_binary(atom_to_list(Application));
    _ ->
      <<"undefined">>
  end.

-spec get_hostname() -> binary().
get_hostname() ->
  {ok, HostName} = inet:gethostname(),
  list_to_binary(HostName).

merge_run_info(Remote, Local) ->
    merge_run_info(Remote, Local, []).

merge_run_info([], _Local, Res) ->
    Res;
merge_run_info([{K, V} | T], Local, Res) ->
    Key = list_to_atom(binary_to_list(K)),
    CurrentValue = proplists:get_value(Key, Local, V),
    merge_run_info(T, Local, [{K, CurrentValue} | Res]).

validate_tables(Procs, Links, _State) ->
  Val         = lists:flatten([[A, B] || {{A, B}, _, _, _}  <- Links]),
  Tempprocs   = lists:usort  ([ A     || {A, _, _, _, _} <- Procs]),
  Templinks   = lists:usort(Val),
  Updateprocs = Templinks -- Tempprocs,

  NewProcs    = update_process_info(Updateprocs, []),
  {Procs ++ NewProcs, Links}.