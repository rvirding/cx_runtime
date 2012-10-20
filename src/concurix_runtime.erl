-module(concurix_runtime).
-export([start/0]).
on_load(start/0).

start() ->
	{ok, Config} = file:consult("concurix.config"),
	T = ets:new(concurix_config, [named_table, {read_concurrency, true}]),
	setup_config(Config, T).
	
setup_config([], T) ->
	ok;
setup_config([{spawn, SpawnConfig} | Tail], T) ->
	io:format("got spawn config of ~p ~n", SpawnConfig),
	lists:foreach(fun(X) -> {{M, F, A}, Size} = X, ets:insert(T, {{M,F}, Size}) end, SpawnConfig),
	setup_config(Tail, T);
setup_config([Head | Tail], T) ->
	%% do something with head
	setup_config(Tail, T).
	