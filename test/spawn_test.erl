-module(spawn_test).
-compile(export_all).

main(N) ->
	spawn(spawn_test, mfaspawn, [N]),
	process_flag(trap_exit, true),
	spawn_link(spawn_test, mfaspawnlink, [N]),
	receive
		{'EXIT', _Pid, N} -> ok;
		X -> X = N   %% deliberately throw an exception here so the test fails
	end,
	spawn_monitor(spawn_test, mfaspawnmonitor, [N]),
	receive
		{'DOWN', _Ref, _Process, _Pid2, N} -> ok;
		X2 -> X2 = N   %% deliberately throw an exception here so the test fails
	end,
        spawn_opt(spawn_test, mfaspawnopt, [N], [{min_heap_size, 233}, {priority, low}]),

        %% Repeat tests with proc_lib spawn functions
	proc_lib:spawn(spawn_test, mfaspawn, [N]),
	proc_lib:spawn_link(spawn_test, mfaspawnlink, [N]),
	receive
		{'EXIT', _Pid3, N} -> ok;
		X3 -> X3 = N   %% deliberately throw an exception here so the test fails
	end,
        proc_lib:spawn_opt(spawn_test, mfaspawnopt, [N], [{min_heap_size, 233}, {priority, low}]),
	ok.

mfaspawn(N) ->
	io:format("Got mfaspawn ok ~p ~n", [N]).
	
mfaspawnlink(N) ->
	io:format("Got mfaspawnlink ok ~p ~n", [N]),
	exit(N).
	
mfaspawnmonitor(N) ->
	io:format("Got mfaspawnmonitor ok ~p ~n", [N]),
	exit(N).

mfaspawnopt(N) ->
	io:format("Got mfaspawnopt ok ~p ~n", [N]).
	
	
	
