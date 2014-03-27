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
         mod_to_behaviours/1,
         get_default_json/1,
         merge_run_info/2,
         careful_process_info/2,
         get_json_for_proxy/1,
         config_option/3,
         config_option/4]).

-record(last_node, {pid, total_heap_size}).

-include("concurix_runtime.hrl").

%%%=============================================================================
%%% External functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc 
%% Returns the value of the config option from a proplist stored within a
%% an other proplist. The second parameter is the key within this larger
%% proplist, the third is the key of the proplist inside.
%% If not found the value of the last parameter is given back.
%% @end
%%------------------------------------------------------------------------------ 
-spec config_option(proplists:proplist(), atom(), atom(), term()) -> term().
config_option(Config, Slot, Key, Default) ->
  case config_option(Config, Slot, Key) of
    undefined -> Default;
    {ok, Value} -> Value
  end.

%%------------------------------------------------------------------------------
%% @doc 
%% Returns the value of the config option from a proplist stored within a
%% an other proplist. The second parameter is the key within this larger
%% proplist, the third is the key of the proplist inside.
%% @end
%%------------------------------------------------------------------------------ 
-spec config_option(proplists:proplist(), atom(), atom()) -> term().
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

%%------------------------------------------------------------------------------
%% @doc
%% process_info is defined to throw an exception if Pid is not local
%%
%% This version verifies that the PID is for the current node
%% The callers to this function already have business logic for 'undefined'
%% @end
%%------------------------------------------------------------------------------
-spec careful_process_info(Pid, Item) -> Result when
  Pid :: pid(),
  Item :: atom(),
  Result :: term().
careful_process_info(Pid, Item) when node(Pid) =:= node() ->
  process_info(Pid, Item);
careful_process_info(_Pid, _Item) ->
  undefined.

%%------------------------------------------------------------------------------
%% @doc
%% Figures out which function started the process instance.
%% @end
%%------------------------------------------------------------------------------
-spec local_translate_initial_call(Pid) -> Result when
  Pid :: pid(),
  Result :: {Module :: atom(), Function :: atom(), Arity :: integer()}.
local_translate_initial_call(Pid) when is_pid(Pid) ->
  proc_lib:translate_initial_call(Pid);
local_translate_initial_call(Pid) when is_atom(Pid) ->
  proc_lib:translate_initial_call(whereis(Pid));
local_translate_initial_call({Pid, _X}) ->
  local_translate_initial_call(Pid).

%%------------------------------------------------------------------------------
%% @doc
%% Returns the directory name as a string which contains the module.
%% @end
%%------------------------------------------------------------------------------
-spec mod_to_service(Mod) -> Result when
  Mod :: atom() | string(),
  Result :: string().
mod_to_service(Mod) when is_list(Mod)->
  mod_to_service(list_to_atom(Mod));
mod_to_service(Mod) ->
  case lists:keyfind(Mod, 1, code:all_loaded()) of
    false->
      Mod;

    {_, Path} ->
      path_to_service(Path)
  end.

%%------------------------------------------------------------------------------
%% @doc
%% Returns the name of the behaviours which is implemented by the module.
%% The names of the behaviours are returned as binaries.
%% @end
%%------------------------------------------------------------------------------
-spec mod_to_behaviours(Mod) -> Result when
  Mod :: atom() | string(),
  Result :: nonempty_list(binary()). 
mod_to_behaviours(unknown) ->
  [<<"undefined">>];
mod_to_behaviours(port) ->
  [<<"port">>];
mod_to_behaviours(Mod) when is_port(Mod) ->
  [<<"port">>];
mod_to_behaviours(Mod) when is_list(Mod) ->
  mod_to_behaviours(list_to_atom(Mod));
mod_to_behaviours(Mod) ->
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

%%------------------------------------------------------------------------------
%% @doc
%%------------------------------------------------------------------------------
-spec update_process_info(Pid) -> Result when
  Pid :: pid(),
  Result :: [{Pid, {M, F, A}, Service, Calls, Behaviours}],
  Pid :: pid(),
  M :: atom(),
  F :: atom(),
  A :: atom(),
  Service :: string(),
  Calls :: integer(),
  Behaviours :: nonempty_list(binary()).
update_process_info(Pid) ->
  update_process_info([Pid], []).

%%------------------------------------------------------------------------------
%% @doc
%%------------------------------------------------------------------------------
-spec update_process_info(Pids, Acc) -> Result when
  Pids :: list(pid()),
  Acc :: list(),
  Result :: list({Pid, {M, F, A}, Service, Calls, Behaviours}),
  Pid :: pid(),
  M :: atom(),
  F :: atom(),
  A :: atom(),
  Service :: string(),
  Calls :: integer(),
  Behaviours :: nonempty_list(binary()).
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
  Behaviours  = mod_to_behaviours(Mod),

  update_process_info(T, [{Pid, {Mod, Fun, Arity}, Service, 1, Behaviours} | Acc]).

%%------------------------------------------------------------------------------
%% @doc
%% Returns the trace data as a json object converted to binary format.
%% The name of the function which implements the calculation of the json 
%% object is specified in the config file. If not specified there,
%% get_default_json/1 will be called.
%% @end
%%------------------------------------------------------------------------------
-spec get_current_json(State :: #tcstate{}) -> binary().
get_current_json(#tcstate{trace_mf = TraceMF} = State) ->
  {Module, Function} = TraceMF,
  Module:Function(State).

%%------------------------------------------------------------------------------
%% @doc
%% Default implementation of the function which calculates the output json.
%% @end
%%------------------------------------------------------------------------------
-spec get_default_json(State :: #tcstate{}) -> binary().
get_default_json(State) ->
  ets:safe_fixtable(State#tcstate.process_table,  true),
  ets:safe_fixtable(State#tcstate.link_table,     true),
  ets:safe_fixtable(State#tcstate.sys_prof_table,  true),
  ets:safe_fixtable(State#tcstate.proc_link_table, true),

  RawProcs       = ets:tab2list(State#tcstate.process_table),
  RawLinks       = ets:tab2list(State#tcstate.link_table),
  RawSys         = ets:tab2list(State#tcstate.sys_prof_table),
  RawProcLink    = ets:tab2list(State#tcstate.proc_link_table),

  {Procs, Links} = validate_tables(RawProcs, RawLinks, State),

  ets:safe_fixtable(State#tcstate.sys_prof_table,  false),
  ets:safe_fixtable(State#tcstate.link_table,     false),
  ets:safe_fixtable(State#tcstate.process_table,  false),
  ets:safe_fixtable(State#tcstate.proc_link_table, false),

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
                     ] ++ delta_info(State#tcstate.last_nodes, Pid)
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

  Run_id = binary_to_list(proplists:get_value(<<"run_id">>, State#tcstate.run_info)),
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

%%------------------------------------------------------------------------------
%% @doc
%% This new implementation which should be used in the config file now
%% will give back a json in the new format required by the proxy server.
%% @end
%%------------------------------------------------------------------------------
-spec get_json_for_proxy(State :: #tcstate{}) -> binary().
get_json_for_proxy(State) ->
  ets:safe_fixtable(State#tcstate.process_table,  true),
  ets:safe_fixtable(State#tcstate.link_table,     true),
  ets:safe_fixtable(State#tcstate.sys_prof_table,  true),
  ets:safe_fixtable(State#tcstate.proc_link_table, true),

  RawProcs       = ets:tab2list(State#tcstate.process_table),
  RawLinks       = ets:tab2list(State#tcstate.link_table),
  RawSys         = ets:tab2list(State#tcstate.sys_prof_table),
  RawProcLink    = ets:tab2list(State#tcstate.proc_link_table),

  {Procs, Links} = validate_tables(RawProcs, RawLinks, State),

  ets:safe_fixtable(State#tcstate.sys_prof_table,  false),
  ets:safe_fixtable(State#tcstate.link_table,     false),
  ets:safe_fixtable(State#tcstate.process_table,  false),
  ets:safe_fixtable(State#tcstate.proc_link_table, false),

  CallTotals = lists:foldl(fun ({{Source, _Target}, NumCalls, _WordsSent, _Start}, Acc) ->
                                   dict:update_counter(Source, NumCalls, Acc)
                           end,
                           dict:new(),
                           Links),
  DisplayPid = State#tcstate.display_pid,
  NumCalls = fun (Pid) ->
                     case dict:find(Pid, CallTotals) of
                         {ok, Value} -> Value;
                         error -> 0
                     end
             end,

  TempProcs      = [ [
                      {id,              pid_to_name(Pid)},
                      {pid,             ospid_to_b()},
                      {name,            pid_to_name(Pid)},
                      {module,[
                        {top, get_module_name_b(DisplayPid, M, Pid)}, 
                        {requireId, term_to_b(M)},
                        {id, mod_to_id(M)}
                      ]},
                      {fun_name,        term_to_b(F)},
                      {next_level,      <<"NaN">>},
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
                     ] ++ delta_info(State#tcstate.last_nodes, Pid)
                     || {Pid, {M, F, A}, Service, Scheduler, Behaviour} <- Procs],

  TempLinks      = [ [{source,          pid_to_name(A)},
                      {target,          pid_to_name(B)},
                      {type,            <<"message">>},
                      {total_delay,     100}, % TODO fixme
                      {start,           Start},
                      {num_calls,       C},
                      {words_sent,      D}] 
                        || {{A, B}, C, D, Start} <- Links],

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
                      {Id, {[{concurix, Create, QCount, QTime, Send, 
                              GC, True, Tail, Return, Free}], _, _}} <- RawSys ],

%  Run_id         = binary_to_list(proplists:get_value(<<"run_id">>, State#tcstate.run_info)),


  {LoadAvg, Cpus} =
    case os:type() of
        {unix, linux} ->
          {ok, LoadAverage} = concurix_cpu_info:get_load_avg(),
          {ok, CpuTimes} = concurix_cpu_info:get_cpu_times(),
          {ok, CpuInfos} = concurix_cpu_info:get_cpu_info(),
          CpuInfos = [[{times, proplists:get_value(proplists:get_value(id, CpuInfo), CpuTimes)} | CpuInfo] || CpuInfo <- CpuInfos],
          {LoadAverage, CpuInfos};
        _ ->
          {[], []}
    end,

  Send           =   [{type,              <<"erlang">>},
                      {version,           get_app_version()},

                      {tracing_interval,   State#tcstate.timer_interval_viz},
                      {hostname,           get_hostname()},

                      {load_avg, LoadAvg},

                      {cpus, Cpus},

                      {process_info, [
                        {memory, erlang:memory()},
                        {uptime, get_node_uptime()},
                        {active_requests, 0},
                        {active_handles, 2},
                        {versions, get_app_versions()},
                        {environment, <<"default">>}
                      ]},

                      {system_info, [
                        {freemem, sys_free_memory()},
                        {totalmem, sys_total_memory()},
                        {arch, os_type()},
                        {platform, os_version()},
                        {uptime, get_node_uptime()}
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

get_module_name_b(false = _DisplayPid, M, _Pid) ->
  term_to_b(M);
get_module_name_b(true = _DisplayPid, M, Pid) ->
  ModBin = term_to_b(M),
  ProcNameBin = term_to_b(try_get_regname(Pid)),
  <<ModBin/binary, <<"/">>/binary, ProcNameBin/binary>>.

try_get_regname(Pid) ->
  case (catch process_info(Pid, registered_name)) of
    {registered_name, Name} -> Name;
    _ -> Pid
  end.

get_app_versions() ->
  [{App, Vsn} || {App, _Desc, Vsn} <- application:which_applications()].

get_app_version() ->
  {ok, App} = application:get_application(?MODULE),
  Apps = application:which_applications(),
  {_Name, _Desc, Vsn} = lists:keyfind(App, 1, Apps),
  list_to_binary(Vsn).

get_node_uptime() ->
  {Result, _} = erlang:statistics(wall_clock),
  Result.

sys_free_memory() ->
  Info = memsup:get_system_memory_data(),
  element(2, lists:keyfind(free_memory, 1, Info)).

sys_total_memory() ->
  Info = memsup:get_system_memory_data(),
  element(2, lists:keyfind(total_memory, 1, Info)).
 
os_type() ->
  atom_to_list(element(1, os:type())).

os_version() ->
  atom_to_list(element(2, os:type())).
