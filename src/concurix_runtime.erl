-module(concurix_runtime).
-export([start/2]).

start(Filename, Options) ->
  case lists:member(msg_trace, Options) of
    true  ->
      {ok, CWD }          = file:get_cwd(),
      Dirs                = code:get_path(),

      {ok, Config, _File} = file:path_consult([CWD | Dirs], Filename),

      application:start(cowboy),
      application:start(crypto),
      application:start(gproc),
      application:start(inets),
      application:start(ranch),
      application:start(ssl),

      %% {Host, list({Path, Handler, Opts})}
      Dispatch = cowboy_router:compile([{'_', [{"/", concurix_trace_socket_handler, []} ]}]),

      %% Name, NbAcceptors, Transport, TransOpts, Protocol, ProtoOpts
      cowboy:start_http(http, 100, [{port, 6788}], [{env, [{dispatch, Dispatch}]}]),

      concurix_trace_client:start(Config);

    false ->
      ok
 end.
 