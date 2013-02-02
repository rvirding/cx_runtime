-module(concurix_trace_socket).

-export([start/0, send/2]).

start() ->
	crypto:start(),
	application:start(ranch),
	application:start(cowboy),
	application:start(gproc),
	application:start(concurix_runtime).
	
send(_Benchrun_id, Json) ->
	case gproc:lookup_pids({p, l, "benchrun_tracing"}) of
		[] ->
			ok;
		_X ->
			gproc:send({p, l, "benchrun_tracing"}, {trace, Json})
	end.
	