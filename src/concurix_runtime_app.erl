-module(concurix_runtime_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
  concurix_runtime_sup:start_link().

stop(_State) ->
  concurix_runtime_sup:stop().
