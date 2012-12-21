-module(concurix_run).
-export([process_runscript/1, do_runscript/2, get_run_info/0, start_trace/2, start_trace/1, start_trace/0, finish_trace/2]).

do_runscript([], RunInfo) ->
	handle_run_end(RunInfo),
	ok;
do_runscript([{sleep, Time} | T], RunInfo) ->
	timer:apply_after(Time, concurix_run, do_runscript, [T, RunInfo]);
do_runscript([{trace_on, Args} | T], RunInfo) ->
	concurix:vm_trace(true, Args, proplists:get_value(run_id, RunInfo)),
	do_runscript(T, RunInfo);
do_runscript([{trace_off, Args} | T], RunInfo) ->
	concurix:vm_trace(false, Args),
	do_runscript(T, RunInfo).

process_runscript(Script) ->
	RunInfo = get_run_info(),
	do_runscript(Script, RunInfo).
	
%%make an http call back to concurix for our run id.
%%right now we'll assume that the synchronous version of httpc works,
%%though we know it has some intermittent problems under chicago boss.
get_run_info() ->
	[{concurix_server, Server}] = 	ets:lookup(concurix_config_master, concurix_server),
	[{api_key, APIkey}] = 			ets:lookup(concurix_config_master, api_key),
	inets:start(),
	Url = "http://" ++ Server ++ "/bench/new_offline_run/" ++ APIkey,
	Reply = httpc:request(Url),
	io:format("url: ~p reply: ~p ~n", [Url, Reply]),
	case Reply of
		{_, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} -> 
			concurix_compile:eval_string(Body);
		_X ->
			{Mega, Secs, Micro} = now(), 
			lists:flatten(io_lib:format("local-~p-~p-~p",[Mega, Secs, Micro]))
	end.
	
handle_run_end(RunInfo) ->
	io:format("RunInfo = ~p ~n", [RunInfo]),
	
	%%Url = proplists:get_value(trace_url, RunInfo),
	%%Fields = proplists:get_value(fields, RunInfo),
	Run_id = proplists:get_value(run_id, RunInfo),
	
	%%concurix_file:transmit_to_s3(Run_id, Url, Fields).
	concurix_bench:invoke_bench_analysis(Run_id).
	
start_trace() ->
	start_trace(10000, [garbage_collection, call]).
start_trace(Duration) ->
	start_trace(Duration, [garbage_collection, call]).
start_trace(Duration, Args) ->
	RunInfo = get_run_info(),
	concurix:vm_trace(true, Args, proplists:get_value(run_id, RunInfo)),
	timer:apply_after(Duration, concurix_run, finish_trace, [RunInfo, Args]).
	
finish_trace(RunInfo, Args) ->
	concurix:vm_trace(false, Args),
	handle_run_end(RunInfo).
	
