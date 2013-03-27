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
%% This gen_server handles functinality exposed by the Concurix's extensions to the
%% erlang system_profile API.
%%
-module(concurix_trace_by_scheduler).

-behaviour(gen_server).

-export([start_link/1]).
-export([handle_system_profile/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("concurix_runtime.hrl").

start_link(State) ->
  gen_server:start_link(?MODULE, [State], []).

init([State]) ->
  SysProfTable = State#tcstate.sysProfTable,
  SysProfPid   = spawn_link(?MODULE, handle_system_profile, [SysProfTable]),

  try erlang:system_profile(SysProfPid, [concurix])
  catch
    _Type:_Exception -> 
      io:format("~n"),
      io:format("The tracer is started but a Concurix feature was not found.~n"),
      io:format("Upgrade to Concurix Erlang for more detailed tracing: http://www.concurix.com/main/products~n"),
      io:format("This version will continue to work without the enhanced functionality.~n"),
      io:format("~n")
  end,

  {ok, undefined}.

handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
handle_info(stop_tracing,                           State) ->
  erlang:system_profile(undefined, [concurix]),
  {stop, normal, State};

handle_info(_Msg, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.

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
 
handle_system_profile(SysProfTable) ->
  receive
    { profile, concurix, SchedulerId,  SchedulerStats, WindowStart, WindowStop } ->
      ets:insert(SysProfTable, {SchedulerId, {SchedulerStats, WindowStart, WindowStop}}),
      handle_system_profile(SysProfTable);

    Other ->
      io:format("OTHER:    ~p~n", [Other]),
      handle_system_profile(SysProfTable)
  end.
 

