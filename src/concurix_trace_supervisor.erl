-module(concurix_trace_supervisor).

-behaviour(supervisor).

-export([start_link/2, stop/1, init/1, stopUpdates/1]).

-include("concurix_runtime.hrl").

-define(TIMER_SEND_DELAY, 5 * 1000).    %% Wait 5 seconds before turning off the senders

start_link(State, Options) ->
  supervisor:start_link(?MODULE, [State, Options]).

stop(Pid) ->
  lists:foreach(fun(X) -> stopTracers(X) end, supervisor:which_children(Pid)),
  timer:apply_after(?TIMER_SEND_DELAY, ?MODULE, stopUpdates, [Pid]),
  ok.

stopTracers({proc, Pid, worker, _Args}) ->
  Pid ! stop_tracing;

stopTracers({prof, Pid, worker, _Args}) ->
  Pid ! stop_tracing;

stopTracers(_Other) ->
  ok.




stopUpdates(Pid) ->
  lists:foreach(fun(X) -> stopUpdaters(X) end, supervisor:which_children(Pid)).

stopUpdaters({viz, Pid, worker, _Args}) ->
  Pid ! stop_updating;

stopUpdaters({s3,  Pid, worker, _Args}) ->
  Pid ! stop_updating;

stopUpdaters(_Other) ->
  ok.








init([State, Options]) ->
  Terminate  = 2 * 1000,

  StateTrace = State#tcstate{collectTraceData = enable_trace(Options)},
  StateProf  = State#tcstate{collectTraceData = enable_prof (Options)},
  StateViz   = State#tcstate{sendUpdates      = enable_viz  (Options)},
  StateS3    = State#tcstate{sendUpdates      = enable_s3   (Options)},

  Children   = [
                 {proc, {concurix_trace_by_process,   start_link, [StateTrace]}, permanent, Terminate, worker, [concurix_trace_by_process]},
                 {prof, {concurix_trace_by_scheduler, start_link, [StateProf]},  permanent, Terminate, worker, [concurix_trace_by_scheduler]},
                 {viz,  {concurix_trace_send_to_viz,  start_link, [StateViz]},   permanent, Terminate, worker, [concurix_trace_send_to_viz]},
                 {s3,   {concurix_trace_send_to_S3,   start_link, [StateS3]},    permanent, Terminate, worker, [concurix_trace_send_to_S3]}
               ],

  {ok, {{one_for_one, 1, 60}, Children}}.


enable_trace(_Options) ->
  true.

enable_prof(_Options) ->
  true.

enable_viz(_Options) ->
  true.

enable_s3(_Options) ->
  true.
