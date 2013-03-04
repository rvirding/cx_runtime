-module(concurix_runtime_sup).

-behaviour(supervisor).

-export([start/1, stop/1, init/1]).

-include("concurix_runtime.hrl").

start(Config) ->
  supervisor:start_link(?MODULE, [Config]).

stop(_State) ->
  ok.

init([Config]) ->

  Terminate = 2 * 1000,

  Children  = [
                {cx_runtime, {concurix_runtime,   start_link, [Config]}, permanent, Terminate, worker, [concurix_trace_by_process]}
              ],

  {ok, {{one_for_one, 1, 60}, Children}}.
