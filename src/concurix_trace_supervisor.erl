-module(concurix_trace_supervisor).

-behaviour(supervisor).

-export([start/1, stop/1, init/1]).

-include("concurix_runtime.hrl").

start(State) ->
  supervisor:start_link(?MODULE, [State]).

stop(_State) ->
  ok.

init([State]) ->
%%  io:format("concurix_trace_supervisor:init/1                         ~p~n", [self()]),

  RunInfo   = State#tcstate.runInfo,
  ProcTable = State#tcstate.processTable,
  LinkTable = State#tcstate.linkTable,
  ProfTable = State#tcstate.sysProfTable,

  Children  = [
                {proc, {concurix_trace_by_process,   start_link, [ProcTable, LinkTable]}, permanent, brutal_kill, worker, [concurix_trace_by_process]},
                {prof, {concurix_trace_by_scheduler, start_link, [ProfTable]},            permanent, brutal_kill, worker, [concurix_trace_by_scheduler]},
                {viz,  {concurix_trace_send_to_viz,  start_link, [State]},                permanent, brutal_kill, worker, [concurix_trace_send_to_viz]},
                {s3,   {concurix_trace_send_to_S3,   start_link, [RunInfo, State]},       permanent, brutal_kill, worker, [concurix_trace_send_to_S3]}
              ],

  {ok, {{one_for_one, 1, 60}, Children}}.
