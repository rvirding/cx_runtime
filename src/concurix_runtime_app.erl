-module(concurix_runtime_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

-include("concurix_runtime.hrl").

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
	{ok, Config} = application:get_env(config),
	io:format("starting concurix runtime with argument ~p ~n", [Config]),
	concurix_runtime_sup:start(Config).

stop(_State) ->
    ok.