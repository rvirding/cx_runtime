-module(concurix_trace_socket).

-export([start/0, send/2]).

start() ->
	crypto:start(),
	application:start(ranch),
	application:start(cowboy),
	application:start(gproc),
	application:start(concurix_trace).
	
send(Benchrun_id, Data) ->
	case gproc:lookup_pids({n, l, "benchrun-"}) of
		[] ->
			ok;
		_X ->
			io:format("beginning data ~p ~n", [Data]),
			Json = lists:flatten(mochijson2:encode(Data)),
			io:format("json to send ~p ~n", [Json]),
			gproc:send({n, l, "benchrun-"}, {trace, Json})
	end.