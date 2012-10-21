-module(concurix_spawn).
-export([concurix_spawn/1, concurix_spawn/3]).

concurix_spawn(Fun) ->
	io:format("got spawn with fun~p ~n", [Fun]),
	spawn(Fun).

concurix_spawn(Mod, Fun, Args) ->
	Size = 190845 - round(163491 * abs(lists:nth(3, Args))),
	%%io:format("spawn size ~p ~n", [Size]),
	spawn_opt(Mod, Fun, Args, [{min_heap_size, round(Size/30)}]).
		
concurix_spawn(Mod, Fun, Args, Bogus) ->
	case ets:lookup(concurix_config, lists:nth(3, Args)) of
		[{_, Size }] ->
			%%io:format("size ~p ~n", [Size]),
			spawn_opt(Mod, Fun, Args, [{min_heap_size, Size + 100}]);
		_X -> 
			%%io:format("didn't find an entry for MFA ~p ~p ~p ~n", [Mod, Fun, Args]),
			spawn(Mod, Fun, Args)
	end.
