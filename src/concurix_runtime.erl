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
-module(concurix_runtime).

-behaviour(gen_server).

-export([start/0, start/2, start_link/0, stop/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
         terminate/2, code_change/3]).

-include("concurix_runtime.hrl").

-define(DEFAULT_TRACE_MF, {?MODULE, get_default_json}).

%%
%% The no-argument start will look for concurix.config, downloading and 
%% installing one if necessary
%%
start() ->
  application:start(inets),
  Result = httpc:request("http://concurix.com/bench/get_config_download/benchcode-381"),
  case Result of
    {ok, {{_, 200, "OK"}, _Headers, Body}} ->
      Config = eval_string(Body),
      internal_start([Config], [msg_trace]);
    Error ->
      io:format("error, could not autoconfigure concurix_runtime ~p ~n", [Error]),
      {error, Error}
  end.
      
start(Filename, Options) ->
  {ok, CWD}           = file:get_cwd(),
  Dirs                = code:get_path(),

  {ok, Config, _File} = file:path_consult([CWD | Dirs], Filename),
  internal_start(Config, Options).

internal_start(Config, Options) ->
  application:start(crypto),
  application:start(inets),

  application:start(ssl),
  application:start(timer),

  ssl:start(),

  ok = application:start(concurix_runtime),

  case tracer_is_enabled(Options) of
    true  ->
      RunInfo = get_run_info(Config),
      gen_server:call(?MODULE, { start_tracer, RunInfo, Options, Config });
    false ->
      { failed, bad_options }
  end.

stop() ->
  gen_server:call(?MODULE, stop_tracer),
  ok.

%%
%% gen_server support
%%

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  {ok, undefined}.

handle_call({start_tracer, RunInfo, Options, Config},  _From, undefined) ->
  io:format("starting Concurix tracing ~n"),
  {ok, APIKey} = concurix_lib:config_option(Config, master, api_key),
  TraceMF = concurix_lib:config_option(Config, master, trace_mf, ?DEFAULT_TRACE_MF),
  DisplayPid = concurix_lib:config_option(Config, master, display_pid, false),
  TimerIntervalViz = 
    concurix_lib:config_option(Config, master, timer_interval_viz, 
                               ?DEFAULT_TIMER_INTERVAL_VIZ),

  State     = #tcstate{run_info             = RunInfo,
                       %% Tables to communicate between data collectors 
                       %% and data transmitters
                       process_table        = setup_ets_table(cx_procinfo),
                       link_table           = setup_ets_table(cx_linkstats),
                       sys_prof_table       = setup_ets_table(cx_sysprof),
                       proc_link_table      = setup_ets_table(cx_proclink),

                       %% Tables to cache information from last snapshot
                       last_nodes           = ets:new(cx_lastnodes, [public, {keypos, 2}]),

                       trace_supervisor     = undefined,

                       collect_trace_data   = undefined,
                       send_updates         = undefined,
                       trace_mf             = TraceMF,
                       api_key              = APIKey,
                       display_pid          = DisplayPid,
                       timer_interval_viz   = TimerIntervalViz},

  fill_initial_tables(State),
  {ok, Sup} = concurix_trace_supervisor:start_link(State, Options),
  {reply, ok, State#tcstate{trace_supervisor = Sup}};

handle_call({start_tracer, _Config, _Options, _Config}, _From, State) ->
  io:format("~p:handle_call/3   start_tracer but tracer is already running~n", [?MODULE]),
  {reply, ok, State};

handle_call(stop_tracer, _From, undefined) ->
  io:format("~p:handle_call/3   stop_tracer  but tracer is not running~n", [?MODULE]),
  {reply, ok, undefined};

handle_call(stop_tracer, _From, State) ->
  concurix_trace_supervisor:stop_tracing(State#tcstate.trace_supervisor),
  {reply, ok, undefined}.


%%
tracer_is_enabled(Options) ->
  tracer_is_enabled(Options, [ msg_trace, enable_sys_profile, enable_send_to_viz ]).

tracer_is_enabled([], _TracerOptions) ->
  false;

tracer_is_enabled([Head | Tail], TracerOptions) ->
  case lists:member(Head, TracerOptions) of
    true  ->
      true;

    false ->
      tracer_is_enabled(Tail, TracerOptions)
  end.

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
  { ok, Server } = concurix_lib:config_option(Config, master, concurix_server),
  { ok, APIkey } = concurix_lib:config_option(Config, master, api_key),

  Url            = "http://" ++ Server ++ "/bench/new_offline_run/" ++ APIkey,
  Reply          = httpc:request(Url),

  LocalRunInfo = 
    case concurix_lib:config_option(Config, master, run_info) of
        undefined -> [];
        {ok, Value} -> Value
    end,

  case Reply of
    {_, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} ->
      RemoteRunInfo = cx_jsx:json_to_term(list_to_binary(Body)),
      concurix_lib:merge_run_info(RemoteRunInfo, LocalRunInfo);
    _ ->
      keys_to_b(LocalRunInfo)
  end.

eval_string(Incoming_String) ->
  String = case lists:last(Incoming_String) of
    $. -> Incoming_String;
    _X -> lists:concat([Incoming_String, "."])
  end,
  {ok, Tokens, _} = erl_scan:string(String),
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
  ets:delete(State#tcstate.process_table),
  ets:delete(State#tcstate.link_table),
  ets:delete(State#tcstate.sys_prof_table),
  ets:delete(State#tcstate.proc_link_table),
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.

%%
%% on startup, we want to pre-populate our process and link tables with existing information
%% so that things like the supervision tree are realized properly.

fill_initial_tables(State) ->
  Processes = processes(),
  fill_initial_proctable(State#tcstate.process_table, Processes),
  fill_initial_proclinktable(State#tcstate.proc_link_table, Processes).
  
fill_initial_proctable(Table, Processes) ->
  ProcList = concurix_lib:update_process_info(Processes, []),
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
  case concurix_lib:careful_process_info(Proc, links) of
    {links, Plinks} ->
      [P || P <- Plinks, is_pid(P)];
    _ ->
      []
  end.

keys_to_b(L) ->
  [{list_to_binary(atom_to_list(K)), V} || {K, V} <- L].
