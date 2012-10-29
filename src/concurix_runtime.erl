-module(concurix_runtime).
-export([start/0, start/1]).
%%-on_load(start/0).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

start() ->
	start("concurix.config").
start(Filename) ->
	io:format("starting Concurix Runtime~n"),
	Dirs = code:get_path(),
	{ok, Config, _File} = file:path_consult(Dirs, Filename),
	setup_ets_tables([concurix_config_master, concurix_config_spawn, concurix_config_memo]),
	setup_config(Config).
	
%% we setup ets tables for configuration now to simplify the compile logic.  this
%% way every table is available even if the particular customer instance does not
%% have any options

setup_ets_tables([]) ->
	ok;
setup_ets_tables([H | T]) ->
	case ets:info(H) of
		undefined ->ok;
		_X -> ets:delete(H)
	end,
	ets:new(H, [named_table, {read_concurrency, true}, {heir, whereis(init), concurix}]),
	setup_ets_tables(T).
	
setup_config([]) ->
	ok;
setup_config([{spawn, SpawnConfig} | Tail]) ->
	lists:foreach(fun(X) -> {{M, F}, Expr} = X, ets:insert(concurix_config_spawn, {{M, F}, Expr}) end, SpawnConfig),
	setup_config(Tail);
setup_config([{memoization, MemoConfig} | Tail]) ->
	lists:foreach(fun(X) -> {{M, F}, Expr} = X, ets:insert(concurix_config_memo, {{M, F}, Expr}) end, MemoConfig),
	setup_config(Tail);
setup_config([{master, MasterConfig} | Tail]) ->
	lists:foreach(fun(X) -> {Key, Val} = X, ets:insert(concurix_config_master, {Key, Val}) end, MasterConfig),
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
	