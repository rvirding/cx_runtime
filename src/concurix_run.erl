-module(concurix_run).
-export([process_runscript/1, do_runscript/2]).

do_runscript([], _RunId) ->
	ok;
do_runscript([{sleep, Time} | T], RunId) ->
	timer:apply_after(Time, concurix_run, do_runscript, [T, RunId]);
do_runscript([{trace_on, Args} | T], RunId) ->
	concurix:vm_trace(true, Args, RunId),
	do_runscript(T, RunId);
do_runscript([{trace_off, Args} | T], RunId) ->
	concurix:vm_trace(false, Args, RunId),
	do_runscript(T, RunId).

process_runscript(Script) ->
	RunId = get_runId(),
	do_runscript(Script, RunId).
	
%%make an http call back to concurix for our run id.
%%right now we'll assume that the synchronous version of httpc works,
%%though we know it has some intermittent problems under chicago boss.
get_runId() ->
	Server = ets:lookup(concurix_config_master, concurix_server),
	User = ets:lookup(concurix_config_master, user),
	APIkey = ets:lookup(concurix_config_master, api_key),
	inets:start(),
	Reply = httpc:request(Server ++ "/main/get_new_runid" ++ User ++ "/" ++ APIkey),
	case Reply of
		{_, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} -> Body;
		_X -> "serverassign"
	end. 
			
	
