-module(concurix_trace_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    %% {Host, list({Path, Handler, Opts})}
    Dispatch = [{'_', [
        {'_', concurix_trace_socket_handler, []}
    ]}],
    %% Name, NbAcceptors, Transport, TransOpts, Protocol, ProtoOpts
    Res = cowboy:start_http(cx_ws_dispatcher, 100,
        [{port, 6788}],
        [{env, [{dispatch, Dispatch}]}]
    ),
	io:format("XXXXXXX Result from opening cowboy port ~p ~n", [Res]),
    concurix_trace_sup:start_link().

stop(_State) ->
    ok.
