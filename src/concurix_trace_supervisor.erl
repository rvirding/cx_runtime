-module(concurix_trace_supervisor).

-behaviour(supervisor).

-export([start/1, stop/1, init/1, stopUpdates/1]).

-include("concurix_runtime.hrl").

-define(TIMER_SEND_DELAY, 5 * 1000).    %% Wait 5 seconds before turning off the senders

start(State) ->
  supervisor:start_link(?MODULE, [State]).

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








init([State]) ->
  ProcTable = State#tcstate.processTable,
  LinkTable = State#tcstate.linkTable,
  ProfTable = State#tcstate.sysProfTable,
	ProcLinkTable = State#tcstate.procLinkTable,

  Terminate = 2 * 1000,

  Children  = [
                {proc, {concurix_trace_by_process,   start_link, [ProcTable, LinkTable, ProcLinkTable]}, permanent, Terminate, worker, [concurix_trace_by_process]},
                {prof, {concurix_trace_by_scheduler, start_link, [ProfTable]},            permanent, Terminate, worker, [concurix_trace_by_scheduler]},
                {viz,  {concurix_trace_send_to_viz,  start_link, [State]},                permanent, Terminate, worker, [concurix_trace_send_to_viz]},
                {s3,   {concurix_trace_send_to_S3,   start_link, [State]},                permanent, Terminate, worker, [concurix_trace_send_to_S3]}
              ],

  {ok, {{one_for_one, 1, 60}, Children}}.
