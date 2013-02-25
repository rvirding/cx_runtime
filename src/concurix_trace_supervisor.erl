-module(concurix_trace_supervisor).

-behaviour(supervisor).

-export([start/1, stop/1, init/1]).

-include("concurix_runtime.hrl").

start(State) ->

  concurix_trace_by_process:start(State#tcstate.processTable, State#tcstate.linkTable),
  concurix_trace_by_scheduler:start(State#tcstate.sysProfTable),

  concurix_trace_send_to_viz:start(State),
  concurix_trace_send_to_S3:start(State#tcstate.runInfo, State),

  ok.

stop(_State) ->
  ok.

init([_Config]) ->
  {ok, undefined}.
 
