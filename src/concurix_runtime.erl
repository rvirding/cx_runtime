-module(concurix_runtime).
-export([start/0, start/1]).
%%-on_load(start/0).

start() ->
	start("concurix.config").
start(Filename) ->
	{ok, Config} = file:consult(Filename),
	setup_ets_tables(),
	setup_config(Config).
	
%% we setup ets tables for configuration now to simplify the compile logic.  this
%% way every table is available even if the particular customer instance does not
%% have any options

setup_ets_tables() ->
	case ets:info(concurix_config_spawn) of
		undefined -> ok;
		_X -> ets:delete(concurix_config_spawn)
	end,
	ets:new(concurix_config_spawn, [named_table, {read_concurrency, true}]),
		
	case ets:info(concurix_config_memo) of
		undefined -> ok;
		_Y -> ets:delete(concurix_config_memo)
	end,
	ets:new(concurix_config_memo, [named_table, {read_concurrency, true}]).
	
setup_config([]) ->
	ok;
setup_config([{spawn, SpawnConfig} | Tail]) ->
	lists:foreach(fun(X) -> {{M, F}, Expr} = X, ets:insert(concurix_config_spawn, {{M, F}, Expr}) end, SpawnConfig),
	setup_config(Tail);
setup_config([{memoization, MemoConfig} | Tail]) ->
	lists:foreach(fun(X) -> {{M, F}, Expr} = X, ets:insert(concurix_config_memo, {{M, F}, Expr}) end, MemoConfig),
	setup_config(Tail);
setup_config([Head | Tail]) ->
	%% do something with head
	io:format("unknown concurix configuration ~p ~n", [Head]),
	setup_config(Tail).
	