-module(concurix_runtime).
-export([start/0, start/1]).
%%-on_load(start/0).

start() ->
	start("concurix.config").
start(Filename) ->
	{ok, Config} = file:consult(Filename),
	setup_config(Config).
	
setup_config([]) ->
	ok;
setup_config([{spawn, SpawnConfig} | Tail]) ->
	case ets:info(concurix_config_spawn) of
		undefined -> ok;
		_X -> ets:delete(concurix_config_spawn)
	end,
	T = ets:new(concurix_config_spawn, [named_table, {read_concurrency, true}]),
	lists:foreach(fun(X) -> {{M, F}, Expr} = X, ets:insert(T, {{M, F}, Expr}) end, SpawnConfig),
	setup_config(Tail);
setup_config([Head | Tail]) ->
	%% do something with head
	io:format("unknown concurix configuration ~p ~n", [Head]),
	setup_config(Tail).
	