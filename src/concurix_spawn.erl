-module(concurix_spawn).
-export([concurix_spawn/1, concurix_spawn/3]).

concurix_spawn(Fun) ->
	io:format("got spawn with fun~p ~n", [Fun]),
	spawn(Fun).
	
concurix_spawn(Mod, Fun, Args) ->
	io:format("got spawn with mod fun args ~p ~p ~p ~n", [Mod, Fun, Args]),
	spawn(Mod, Fun, Args).