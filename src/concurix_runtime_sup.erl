-module(concurix_runtime_sup).

-behaviour(supervisor).

-export([start_link/0, stop/1, init/1]).

start_link() ->
  supervisor:start_link(?MODULE, []).

stop(_State) ->
  ok.

init([]) ->
  Children = [
               {cx_runtime, {concurix_runtime, start_link, []}, permanent, 2000, worker, [concurix_runtime]}
             ],

  {ok, {{one_for_one, 1, 60}, Children}}.
