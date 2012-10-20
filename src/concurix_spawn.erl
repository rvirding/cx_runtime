-module(concurix_spawn).
-export([concurix_spawn/1, concurix_spawn/3]).

concurix_spawn(Fun) ->
	io:format("got spawn with fun~p ~n", [Fun]),
	spawn(Fun).
	
concurix_spawn(Mod, Fun, Args) ->
	case ets:lookup(concurix_config, {Mod, Fun, lists:nth(3, Args)}) of
		[{{Mod, Fun, _}, Size }] ->
			%%io:format("size ~p ~n", [Size]),
			spawn_opt(Mod, Fun, Args, [{min_heap_size, Size + 100}]);
		_X -> 
			%%io:format("didn't find an entry for MFA ~p ~p ~p ~n", [Mod, Fun, Args]),
			spawn(Mod, Fun, Args)
	end.
