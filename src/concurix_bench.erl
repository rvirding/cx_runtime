-module(concurix_bench).
-export([invoke_bench_analysis/1]).

%% we will need to send up files securely eventually
invoke_bench_analysis(Benchrun_id) ->
	inets:start(),
	%% TODO this needs to be changed to the main concurix server.
	Callback = http_uri:encode("http://localhost:8001/bench/process_analysis_results/" ++ Benchrun_id),
	Url = "http://localhost:8002/main/local_analyze/" ++ Benchrun_id ++ "/" ++ Callback,
	
	Response = httpc:request(
		get,
		{Url,[]},
		[],
		[{sync, true}]),
	
	case Response of
		{_, {{_Version, 200, _ReasonPhrase}, _Headers, _Body}} ->
			io:format("bench analysis complete ~n"),
			ok;
		{_, {error, _Reason }} ->
			error;
		_Else ->
			error
	end.