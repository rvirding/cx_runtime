-module(concurix_trace_client).

-export([start_trace_client/0, send_summary/1, stop_trace_client/0]).

-record(tcstate, {proctable, linktable, runinfo}).

stop_trace_client() ->
	%% TODO when this is a gen server clean up the ets tables too 
	dbg:stop_clear().
	
start_trace_client() ->
	concurix_trace_socket:start(),
	dbg:start(),
	Stats = ets:new(linkstats, [public, named_table]),
	Procs = ets:new(procinfo, [public, named_table]),
	%% TODO -- use real auth, send to both s3 for storage as well as cx for dynamic display
	RunInfo = concurix_run:get_run_info(),	
	State = #tcstate{proctable = Procs, linktable = Stats, runinfo = RunInfo},
	
	Pid = dbg:tracer(process, {fun(A,B) -> handle_trace_message(A,B) end, State }),
	dbg:p(all, [s,p]),
	timer:apply_interval(2000, concurix_trace_client, send_summary, [State]),
	ok.

handle_trace_message({trace, Sender, send, Data, Recipient}, State) ->
	update_proc_table([Sender, Recipient], State, []),
	case ets:lookup(State#tcstate.linktable, {Sender, Recipient}) of
		[] ->
			ets:insert(State#tcstate.linktable, {{Sender, Recipient}, 1});
		_X ->
			ets:update_counter(State#tcstate.linktable, {Sender, Recipient}, 1)
	end,	
	State;
handle_trace_message({trace, Pid, exit, Reason}, State) ->
	ets:safe_fixtable(State#tcstate.proctable, true),
	ets:safe_fixtable(State#tcstate.linktable, true),	
	ets:select_delete(State#tcstate.linktable, [ { {{'_', Pid},'_'}, [], [true]}, { {{Pid, '_'}, '_'}, [], [true] } ]),
	ets:select_delete(State#tcstate.proctable, [ { {Pid, '_', '_'}, [], [true]}]),
	ets:safe_fixtable(State#tcstate.linktable, false),		
	ets:safe_fixtable(State#tcstate.proctable, false),	
	State;
handle_trace_message({trace, Creator, spawn, Pid, Data}, State) ->
	case Data of 
		{proc_lib, init_p, _ProcInfo} ->
			{Mod, Fun, Arity} = local_translate_initial_call(Pid),
			ok;
		{erlang, apply, [TempFun, Args]} ->
			{Mod, Fun, Arity} = decode_anon_fun(TempFun);
		{Mod, Fun, Args} ->
			Arity = length(Args),
			ok;
		X ->
			io:format("got unknown spawn of ~p ~n", [X]),
			Mod = unknown,
			Fun = X,
			Arity = 0
	end,
	Service = mod_to_service(Mod),
	Key = {Pid, {Mod, Fun, Arity}, Service},
	ets:insert(State#tcstate.proctable, Key),
	%% also include a link from the creator process to the created.
	update_proc_table([Creator], State, []),
	ets:insert(State#tcstate.linktable, {{Creator, Pid}, 1}),
	State;
handle_trace_message(Msg, State) ->
	%%io:format("msg = ~p ~n", [Msg]),
	State.
	
send_summary(State)->
	ets:safe_fixtable(State#tcstate.proctable, true),
	ets:safe_fixtable(State#tcstate.linktable, true),

	RawProcs  = ets:tab2list(State#tcstate.proctable),
	RawLinks  = ets:tab2list(State#tcstate.linktable),

	{Procs, Links} = validate_tables(RawProcs, RawLinks, State),
	
	ets:safe_fixtable(State#tcstate.linktable, false),		
	ets:safe_fixtable(State#tcstate.proctable, false),

	TempProcs = [ [{name, pid_to_s(Pid)}, {module, term_to_s(M)}, {function, term_to_s(F)}, {arity, A}, local_process_info(Pid, reductions), {service, Service}] || {Pid, {M, F, A}, Service} <- Procs ],
	TempLinks = [ [{source, pid_to_s(A)}, {target, pid_to_s(B)}, {value, C}] || {{A, B}, C} <- Links],
	
		
	Send = [{nodes, TempProcs}, {links, TempLinks}],

	Data = lists:flatten(io_lib:format("~p", [Send])),

	Encoded = "data=" ++ http_uri:encode(Data),
	RunId   = proplists:get_value(run_id, State#tcstate.runinfo),
	[{api_key, APIkey}] = 			ets:lookup(concurix_config_master, api_key),
	
	Url = "http://localhost:8001/bench/process_graph_data/" ++ RunId ++ "/" ++ APIkey,
	Reply = httpc:request(post, {Url, [], "application/x-www-form-urlencoded", Encoded}, [], []),
	case Reply of
		{_, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} -> 
			ok = concurix_compile:eval_string(Body);
		_X ->
			{Mega, Secs, Micro} = now(), 
			lists:flatten(io_lib:format("local-~p-~p-~p",[Mega, Secs, Micro]))
	end,
	
	%%now send to the websocket
	concurix_trace_socket:send(RunId, Send).
	
pid_to_s(Pid) ->
	lists:flatten(io_lib:format("~p", [Pid])).

term_to_s(Term) ->
	lists:flatten(io_lib:format("~p", [Term])).	
%
%
update_proc_table([], State, Acc) ->
	Acc;
update_proc_table([Pid | Tail], State, Acc) ->
	case ets:lookup(State#tcstate.proctable, Pid) of
		[] ->
			[{Pid, {Mod, Fun, Arity}, Service}] = update_process_info(Pid),
			NewAcc = Acc ++ [{Pid, {Mod, Fun, Arity}, Service}],
			ets:insert(State#tcstate.proctable, {Pid, {Mod, Fun, Arity}, Service});
		_X ->
			NewAcc = Acc
	end,
	update_proc_table(Tail, State, NewAcc).
	
local_process_info(Pid, reductions) when is_pid(Pid) ->
	case process_info(Pid, reductions) of
		undefined ->
			{reductions, 1};
		X ->
			X
	end;
local_process_info(Pid, initial_call) when is_pid(Pid) ->
	case process_info(Pid, initial_call) of
		undefined ->
			{initial_call, {unknown, unknown, 0}};
		X ->
			X
	end;
local_process_info(Pid, current_function) when is_pid(Pid) ->
	case process_info(Pid, current_function) of
		undefined ->
			{current_function, {unknown, unknown, 0}};
		X ->
			X
	end;
local_process_info(Pid, Key) when is_atom(Pid) ->
	local_process_info(whereis(Pid), Key);
local_process_info(Pid, reductions) when is_port(Pid) ->
	{reductions, 1};
local_process_info(Pid, initial_call) when is_port(Pid) ->
	Info = erlang:port_info(Pid),
	{initial_call, {port, proplists:get_value(name, Info), 0}}.
	
local_translate_initial_call(Pid) when is_pid(Pid) ->
	proc_lib:translate_initial_call(Pid);
local_translate_initial_call(Pid) when is_atom(Pid) ->
	proc_lib:translate_initial_call(whereis(Pid)).
	
decode_anon_fun(Fun) ->
	Str = lists:flatten(io_lib:format("~p", [Fun])),
	case string:tokens(Str, "<") of
		["#Fun", Name] ->
			[Mod | _] = string:tokens(Name, ".");
		X ->
			io:format("yikes, could not decode ~p of ~p ~n", [Fun, Str]),
			Mod = "anon_function"
	end,
	{Mod, Str, 0}.
	
mod_to_service(Mod) when is_list(Mod)->
	mod_to_service(list_to_atom(Mod));
mod_to_service(Mod) ->
	case lists:keyfind(Mod, 1, code:all_loaded()) of
	 	false->
			Mod;
		{_, Path} ->
			path_to_service(Path)
	end.
	
path_to_service(preloaded) ->
	preloaded;
path_to_service(Path) ->
	Tokens = string:tokens(Path, "/"),
	case lists:reverse(Tokens) of 
		[_, "ebin", Service | _] ->
			Service;
		[Service | _] ->
			Service;
		_X ->
			Path
	end.

update_process_info(Pid) ->
	update_process_info([Pid], []).
update_process_info([], Acc) ->
	Acc;
update_process_info([Pid | T], Acc) ->
	case local_process_info(Pid, initial_call) of
		{initial_call, MFA} ->
			case MFA of 
				{proc_lib, init_p, _} ->
					{Mod, Fun, Arity} = local_translate_initial_call(Pid);
				{erlang, apply, _} ->
					%% we lost the original MFA, take a best guess from the
					%% current function
					{current_function, {Mod, Fun, Arity}} = local_process_info(Pid, current_function);
				{Mod, Fun, Arity} ->
					ok
			end;
		_X ->
			Mod = unknown,
			Fun = Pid,
			Arity = 0
	end,
	Service = mod_to_service(Mod),
	NewAcc = Acc ++ [{Pid, {Mod, Fun, Arity}, Service}],
	update_process_info(T, NewAcc).
		
validate_tables(Procs, Links, State) ->
	Val = lists:flatten([[A, B] || {{A, B}, _} <- Links]),
	Tempprocs = lists:usort([ A || {A, _, _} <-Procs ]),
	Templinks = lists:usort(Val),
	Updateprocs = Templinks -- Tempprocs,	
	
	NewProcs = update_process_info(Updateprocs, []),
	{Procs ++ NewProcs, Links}.	
