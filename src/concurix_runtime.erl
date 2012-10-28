-module(concurix_runtime).
-export([start/0, start/1]).
%%-on_load(start/0).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

start() ->
	start("concurix.config").
start(Filename) ->
	io:format("starting Concurix Runtime ~p ~n", [erlang:process_info(self())]),
	Dirs = code:get_path(),
	{ok, Config, _File} = file:path_consult(Dirs, Filename),
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
	ets:new(concurix_config_spawn, [named_table, {read_concurrency, true}, {heir, whereis(init), concurix}]),
		
	case ets:info(concurix_config_memo) of
		undefined -> ok;
		_Y -> ets:delete(concurix_config_memo)
	end,
	ets:new(concurix_config_memo, [named_table, {read_concurrency, true}, {heir, whereis(init), concurix}]).
	
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
	
%%
%% TEST CODE here
%%
-ifdef(TEST).
empty_test() ->
	concurix_runtime:start("../test/empty.config"),
	{ok, Mod} = compile:file("../test/mandelbrot.erl", [{parse_transform, concurix_transform}]),
	Mod:main(100).
	
mandelbrot_test() ->
	concurix_runtime:start("../test/mandel_test.config"),
	{ok, Mod} = compile:file("../test/mandelbrot.erl", [{parse_transform, concurix_transform}]),
	Mod:main(100).

spawn_test() ->
	concurix_runtime:start("../test/spawn_test.config"),
	{ok, Mod} = compile:file("../test/spawn_test.erl", [{parse_transform, concurix_transform}]),
	Mod:main(100).
	
-endif. %% endif TEST
	