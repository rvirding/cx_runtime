-module(concurix_runtime_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    %%% TODO (Mike) this is unbelievably evil
    case ets:info(concurix_config_master) of
	undefined ->
		concurix_runtime:start("concurix.config");
	_X -> ok
    end,
    %% {Host, list({Path, Handler, Opts})}
    Dispatch = cowboy_router:compile([{'_', [
        {"/", concurix_trace_socket_handler, []}
    ]}]),
    %% Name, NbAcceptors, Transport, TransOpts, Protocol, ProtoOpts
    Res = cowboy:start_http(http, 100,
        [{port, 6788}],
        [{env, [{dispatch, Dispatch}]}]
    ),
    {ok, Pid} = concurix_runtime_sup:start_link(),
	{ok, Pid, Res}.

stop(_State) ->
    ok.
