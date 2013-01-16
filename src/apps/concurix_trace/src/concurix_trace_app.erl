-module(concurix_trace_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, start/0]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    %% {Host, list({Path, Handler, Opts})}
    Dispatch = [{'_', [
        {'_', concurix_trace_socket_handler, []}
    ]}],
    %% Name, NbAcceptors, Transport, TransOpts, Protocol, ProtoOpts
    cowboy:start_http(cx_ws_dispatcher, 100,
        [{port, 8003}],
        [{env, [{dispatch, Dispatch}]}]
    ),
    concurix_trace_sup:start_link().

stop(_State) ->
    ok.

start() ->
	crypto:start(),
	application:start(ranch),
	application:start(cowboy),
	application:start(concurix_trace).