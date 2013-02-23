-module(concurix_run).
-export([process_runscript/1, do_runscript/2, start_trace/2, start_trace/1, start_trace/0, finish_trace/2]).

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
	RunInfo = concurix_trace_client:get_run_info(),
	do_runscript(Script, RunInfo).
	
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
	RunInfo = concurix_trace_client:get_run_info(),
	concurix:vm_trace(true, Args, proplists:get_value(run_id, RunInfo)),
	timer:apply_after(Duration, concurix_run, finish_trace, [RunInfo, Args]).
	
finish_trace(RunInfo, Args) ->
	concurix:vm_trace(false, Args),
	handle_run_end(RunInfo).
	
