-module(concurix_runtime).
-export([start/0, start/1, start_config/1, start_text/1, setup_ets_tables/1, setup_config/1]).
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
	start_config(Config).

start_text(Text) ->
	Config = concurix_compile:eval_string(Text),
	start_config(Config).
		
start_config(Config) ->
	setup_ets_tables([concurix_config_master, concurix_config_spawn, concurix_config_memo]),
	erase(run_commands),
	setup_config(Config).
	
%% we setup ets tables for configuration now to simplify the compile logic.  this
%% way every table is available even if the particular customer instance does not
%% have any options

setup_ets_tables([]) ->
	ok;
setup_ets_tables([H | T]) ->
	case ets:info(H) of
		undefined -> ets:new(H, [public, named_table, {read_concurrency, true}, {heir, whereis(init), concurix}]);
		_X -> ets:delete_all_objects(H)
	end,
	setup_ets_tables(T).
	
setup_config([]) ->
	case get(run_commands) of
		undefined -> ok;
		X -> concurix_run:process_runscript(X)
	end;
setup_config([{spawn, SpawnConfig} | Tail]) ->
	lists:foreach(fun(X) -> {{M, F}, Expr} = X, ets:insert(concurix_config_spawn, {{M, F}, Expr}) end, SpawnConfig),
	setup_config(Tail);
setup_config([{memoization, MemoConfig} | Tail]) ->
	lists:foreach(fun(X) -> {{M, F}, Expr} = X, ets:insert(concurix_config_memo, {{M, F}, Expr}) end, MemoConfig),
	setup_config(Tail);
setup_config([{master, MasterConfig} | Tail]) ->
	io:format('got master config ~p ~n', [MasterConfig]),
	lists:foreach(fun(X) -> {Key, Val} = X, ets:insert(concurix_config_master, {Key, Val}) end, MasterConfig),
	setup_config(Tail);
setup_config([{run, RunConfig} | Tail]) ->
	put(run_commands, RunConfig), %%we'll run the instrumentation work *after* we've had a chance to finish initializing
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
	%% Purge the module loaded by empty_test, so we'll load the one compiled below.
	true = code:soft_purge(mandelbrot),
	{ok, Mod} = compile:file("../test/mandelbrot.erl", [{parse_transform, concurix_transform}]),
	Mod:main(100).

spawn_test () ->
	concurix_runtime:start("../test/spawn_test.config"),
	{ok, Mod} = compile:file("../test/spawn_test.erl", [{parse_transform, concurix_transform}]),
	Mod:main(100).
	
master_test()->
 	concurix_runtime:start("../test/master_test.config"),
 	[{concurix_server, "localhost:8001"}] = ets:lookup(concurix_config_master, concurix_server),
 	[{user, "alex@concurix.com"}] = ets:lookup(concurix_config_master, user).

run_test() ->
	concurix_runtime:start("../test/run_test.config"),
	%%wait five seconds.  the run commands should do their stuff in the meantime
	timer:sleep(1000).
	
start_config_test() ->
	{ok, Config} = file:consult("../test/start_config_test.config"),
	concurix_runtime:start_config(Config),
 	[{concurix_server, "localhost:8001"}] = ets:lookup(concurix_config_master, concurix_server),
 	[{user, "alex@concurix.com"}] = ets:lookup(concurix_config_master, user),
	{ok, _Mod} = compile:file("../test/spawn_test.erl", [{parse_transform, concurix_transform}]).

start_text_test() ->
	{ok, Bin } = file:read_file("../test/start_text_test.config"),
	Text = binary_to_list(Bin),
	concurix_runtime:start_text(Text),
 	[{concurix_server, "localhost:8001"}] = ets:lookup(concurix_config_master, concurix_server),
 	[{user, "alex@concurix.com"}] = ets:lookup(concurix_config_master, user),
	{ok, _Mod} = compile:file("../test/spawn_test.erl", [{parse_transform, concurix_transform}]).
		
-endif. %% endif TEST
	
