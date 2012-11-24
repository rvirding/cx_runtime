-module(concurix_run).
-export([process_runscript/1, do_runscript/2, get_runId/0]).

do_runscript([], _RunId) ->
	ok;
do_runscript([{sleep, Time} | T], RunId) ->
	timer:apply_after(Time, concurix_run, do_runscript, [T, RunId]);
do_runscript([{trace_on, Args} | T], RunId) ->
	concurix:vm_trace(true, Args, RunId),
	do_runscript(T, RunId);
do_runscript([{trace_off, Args} | T], RunId) ->
	concurix:vm_trace(false, Args),
	do_runscript(T, RunId).

process_runscript(Script) ->
	RunId = get_runId(),
	do_runscript(Script, RunId).
	
%%make an http call back to concurix for our run id.
%%right now we'll assume that the synchronous version of httpc works,
%%though we know it has some intermittent problems under chicago boss.
get_runId() ->
	[{concurix_server, Server}] = 	ets:lookup(concurix_config_master, concurix_server),
	[{api_key, APIkey}] = 			ets:lookup(concurix_config_master, api_key),
	inets:start(),
	Url = "http://" ++ Server ++ "/bench/new_run/" ++ APIkey,
	Reply = httpc:request(Url),
	io:format("url: ~p reply: ~p ~n", [Url, Reply]),
	case Reply of
		{_, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} -> concurix_compile:eval_string(Body);
	
		_X ->
			{Mega, Secs, Micro} = now(), 
			lists:flatten(io_lib:format("local-~p-~p-~p",[Mega, Secs, Micro]))
	end. 
			