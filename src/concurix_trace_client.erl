-module(concurix_trace_client).

-export([start_trace_client/0, send_summary/1]).

start_trace_client() ->
	Ets = ets:new(stats, [public, named_table]),
	Pid = dbg:trace_client(ip, 7999, {fun(A,B) -> handle_trace_message(A,B) end, Ets }),
	timer:apply_interval(2000, concurix_trace_port, send_summary, [Ets]).

handle_trace_message({trace, Sender, send, Data, Recipient}, State) ->
	case ets:lookup(State, {Sender, Recipient}) of
		[] ->
			ets:insert(State, {{Sender, Recipient}, 1});
		_X ->
			ets:update_counter(State, {Sender, Recipient}, 1)
	end,	
	State;
handle_trace_message({trace, Pid, exit, Reason}, State) ->
	io:format("trying to delete process ~p size ~p ~n", [Pid, ets:info(State, size)]),
	Sel = ets:select(State, [ { {{'_', Pid},'_'}, [], ['$_']}, { {{Pid, '_'}, '_'}, [], ['$_'] } ]),
	io:format("found object Sel ~p in table ~n", [Sel]),
	ets:select_delete(State, [ { {{'_', Pid},'_'}, [], [true]}, { {{Pid, '_'}, '_'}, [], [true] } ]),
	io:format("now size is ~p ~n", [ets:info(State, size)]),
	State;
handle_trace_message(Msg, State) ->
	%%io:format("msg = ~p ~n", [Msg]),
	State.
	
send_summary(Table)->
	Counts = ets:tab2list(Table),
	Data = lists:flatten(io_lib:format("~p", [Counts])),
	%% TODO -- use real auth, send to both s3 for storage as well as cx for dynamic display
	RunInfo = concurix_run:get_run_info(),
	Encoded = http_uri:encode(Counts),
	RunId   = proplists:get_value(run_id, RunInfo),
	[{api_key, APIkey}] = 			ets:lookup(concurix_config_master, api_key),
	
	Url = "http://localhost:8001/bench/process_graph_data/" ++ RunId ++ "/" ++ APIkey,
	Reply = httpc:request(post, {Url, [], "application/x-www-form-urlencoded", Encoded}, [], []),
	io:format("url: ~p reply: ~p ~n", [Url, Reply]),
	case Reply of
		{_, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} -> 
			ok = concurix_compile:eval_string(Body);
		_X ->
			{Mega, Secs, Micro} = now(), 
			lists:flatten(io_lib:format("local-~p-~p-~p",[Mega, Secs, Micro]))
	end.