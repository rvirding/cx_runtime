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
%% The second supervisor for Concurix Runtime; this one supervises the tracers and senders
%% that are running.  It is currently owned by the primary gen_server concurix_runtime
%%

-module(concurix_trace_supervisor).

-behaviour(supervisor).

-export([start_link/2, init/1, stop_tracing/1, stop_sending/1]).

-include("concurix_runtime.hrl").

-define(TIMER_SEND_DELAY, 5 * 1000).    %% Wait 5 seconds before turning off the senders

start_link(State, Options) ->
  supervisor:start_link(?MODULE, [State, Options]).


init([State, Options]) ->
  Terminate  = 2 * 1000,

  StateTrace = State#tcstate{collect_trace_data = enable_trace(Options)},
  StateViz   = State#tcstate{send_updates       = enable_viz  (Options)},

  Children   = [
                 {proc, {concurix_trace_by_process,   start_link, [StateTrace]}, transient, Terminate, worker, [concurix_trace_by_process]},
                 {viz,  {concurix_trace_send_to_viz,  start_link, [StateViz]},   transient, Terminate, worker, [concurix_trace_send_to_viz]}
               ],

  {ok, {{one_for_one, 1, 60}, Children}}.


enable_trace(_Options) ->
  true.

enable_viz(_Options) ->
  true.

%% Exported API for starting and stopping the 2 collectors and 2 transmitters owned by this supervisor
stop_tracing(Pid) ->
  lists:foreach(fun(X) -> stopTracers(X) end, supervisor:which_children(Pid)),
  timer:apply_after(?TIMER_SEND_DELAY, ?MODULE, stop_sending, [Pid]),
  ok.

stop_sending(Pid) ->
  lists:foreach(fun(X) -> stopSenders(X) end, supervisor:which_children(Pid)).



%% Stop the two data collectors
stopTracers({proc, Pid, worker, _Args}) ->
  Pid ! stop_tracing;

stopTracers({prof, Pid, worker, _Args}) ->
  Pid ! stop_tracing;

stopTracers(_Other) ->
  ok.


%% Stop the two data senders
stopSenders({viz, Pid, worker, _Args}) ->
  Pid ! stop_updating;

stopSenders(_Other) ->
  ok.

