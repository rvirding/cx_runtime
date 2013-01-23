-module(concurix_trace_client).

-export([start_trace_client/0, send_summary/1, send_snapshot/1, stop_trace_client/0, handle_system_profile/1]).

-record(tcstate, {proctable, linktable, sptable, runinfo, sp_pid}).

stop_trace_client() ->
	%% TODO when this is a gen server clean up the ets tables too 
	dbg:stop_clear().
	
start_trace_client() ->
	concurix_trace_socket:start(),
	dbg:start(),
	Stats = ets:new(linkstats, [public, named_table]),
	Procs = ets:new(procinfo, [public, named_table]),
	Prof  = ets:new(sysprof, [public, named_table]),
	
	RunInfo = concurix_run:get_run_info(),	
	Sp_pid = spawn(concurix_trace_client, handle_system_profile, [Prof]),
	State = #tcstate{proctable = Procs, linktable = Stats, sptable = Prof, runinfo = RunInfo, sp_pid = Sp_pid},
	
	%% now turn on the tracing
	Pid = dbg:tracer(process, {fun(A,B) -> handle_trace_message(A,B) end, State }),
	dbg:p(all, [s,p]),
	erlang:system_profile(Sp_pid, [concurix]),
	
	%% every two seconds send a web socket update.  every two minutes save to s3.
	
	timer:apply_interval(2000, concurix_trace_client, send_summary, [State]),
	timer:apply_interval(120000, concurix_trace_client, send_snapshot, [State]),
	ok.

handle_system_profile(Proftable) ->
    receive
      { profile, concurix, Id,  Summary, TimestampStart, TimestampStop } ->
		ets:insert(Proftable, {Id, {Summary, TimestampStart, TimestampStop}}),
        io:format("PROFILE-SUMMARY:  ~p ~p ~p ~p~n", [TimestampStart, TimestampStop, Id, Summary]),
        handle_system_profile(Proftable);
      Other ->
        io:format("OTHER:    ~p~n", [Other]),
        handle_system_profile(Proftable)
    end.
	
handle_trace_message({trace, Sender, send, Data, Recipient}, State) ->
	update_proc_table([Sender, Recipient], State, []),
	case ets:lookup(State#tcstate.linktable, {Sender, Recipient}) of
		[] ->
			ets:insert(State#tcstate.linktable, {{Sender, Recipient}, 1});
		_X ->
			ets:update_counter(State#tcstate.linktable, {Sender, Recipient}, 1)
	end,	
	State;
handle_trace_message({trace, Pid, exit, _Reason}, State) ->
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
	
get_current_json(State) ->
	ets:safe_fixtable(State#tcstate.proctable, true),
	ets:safe_fixtable(State#tcstate.linktable, true),
	ets:safe_fixtable(State#tcstate.sptable, true),

	RawProcs  = ets:tab2list(State#tcstate.proctable),
	RawLinks  = ets:tab2list(State#tcstate.linktable),
	RawSys	  = ets:tab2list(State#tcstate.sptable),

	{Procs, Links} = validate_tables(RawProcs, RawLinks, State),
	
	ets:safe_fixtable(State#tcstate.linktable, false),		
	ets:safe_fixtable(State#tcstate.proctable, false),
	ets:safe_fixtable(State#tcstate.sptable, false),

	TempProcs = [ [{name, pid_to_b(Pid)}, {module, term_to_b(M)}, {function, term_to_b(F)}, {arity, A}, term_to_b(local_process_info(Pid, reductions)), term_to_b({service, Service})] || {Pid, {M, F, A}, Service} <- Procs ],
	TempLinks = [ [{source, pid_to_b(A)}, {target, pid_to_b(B)}, {value, C}] || {{A, B}, C} <- Links],
	Schedulers = [ [{scheduler, Id}, {quanta_count, QCount}, {quanta_time, QTime}, {send, Send}, {gc, GC}, {true_call_count, True}, {tail_call_count, Tail}, {return_count, Return}, {process_free, Free}] || {Id, {[QCount, QTime, Send, GC, True, Tail, Return, Free], _, _}} <- RawSys ],
	
		
	Send = [{nodes, TempProcs}, {links, TempLinks}, {schedulers, Schedulers}],

	Data = lists:flatten(io_lib:format("~p", [Send])),
	lists:flatten(mochijson2:encode([{data, Send}])).

send_summary(State)->
	Json 		= get_current_json(State),
	Run_id 		= proplists:get_value(run_id, State#tcstate.runinfo),	
	%%now send to the websocket
	concurix_trace_socket:send(Run_id, Json).
	
send_snapshot(State) ->
	Json	 	= get_current_json(State),
	Run_id 		= proplists:get_value(run_id, State#tcstate.runinfo),
	Url 		= proplists:get_value(trace_url, State#tcstate.runinfo),
	Fields 		= proplists:get_value(fields, State#tcstate.runinfo),
	{Mega, Secs, Micro} = now(),
	Key 		= lists:flatten(io_lib:format("json_realtime_trace_snapshot.~p.~p-~p-~p",[node(), Mega, Secs, Micro])),
	
	concurix_file:transmit_data_to_s3(Run_id, Key, list_to_binary(Json), Url, Fields).
	
pid_to_b(Pid) ->
	list_to_binary(lists:flatten(io_lib:format("~p", [Pid]))).

term_to_b({Key, Value}) ->
	Bin = term_to_b(Value),
	{Key, Bin};
term_to_b(Term) ->
	list_to_binary(lists:flatten(io_lib:format("~p", [Term]))).
		
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
