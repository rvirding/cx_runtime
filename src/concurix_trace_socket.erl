-module(concurix_trace_socket).

-export([start/0, send/2]).

start() ->
	crypto:start(),
	application:start(ranch),
	application:start(cowboy),
	application:start(gproc),
	application:start(concurix_runtime).
	
send(Benchrun_id, Json) ->
	case gproc:lookup_pids({n, l, "benchrun-"}) of
		[] ->
			ok;
		_X ->
			gproc:send({n, l, "benchrun-"}, {trace, Json})
	end.
	