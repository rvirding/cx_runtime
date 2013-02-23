-module(concurix_runtime).
-export([start/0, start/1, start/2, start_config/1, start_text/1, setup_ets_tables/1, setup_config/1]).
%%-on_load(start/0).

start() ->
	start("concurix.config").

start(Filename) ->
        {ok, CWD }          = file:get_cwd(),
        Dirs                = code:get_path(),

        {ok, Config, _File} = file:path_consult([CWD | Dirs], Filename),
	start_config(Config).


start(Filename, Options) ->
	start(Filename),
	case lists:member(msg_trace, Options) of
		true ->
			concurix_trace_socket:start();
		false ->
			ok
	end.
	
start_text(Text) ->
	Config = concurix_compile:eval_string(Text),
	start_config(Config).
		
start_config(Config) ->
	setup_ets_tables([concurix_config_master, concurix_config_spawn, concurix_config_memo]),
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
        ok;
setup_config([{spawn, SpawnConfig} | Tail]) ->
	lists:foreach(fun(X) -> {{M, F}, Expr} = X, ets:insert(concurix_config_spawn, {{M, F}, Expr}) end, SpawnConfig),
	setup_config(Tail);
setup_config([{memoization, MemoConfig} | Tail]) ->
	lists:foreach(fun(X) -> {{M, F}, Expr} = X, ets:insert(concurix_config_memo, {{M, F}, Expr}) end, MemoConfig),
	setup_config(Tail);
setup_config([{master, MasterConfig} | Tail]) ->
	%%io:format('got master config ~p ~n', [MasterConfig]),
	lists:foreach(fun(X) -> {Key, Val} = X, ets:insert(concurix_config_master, {Key, Val}) end, MasterConfig),
	setup_config(Tail);
setup_config([Head | Tail]) ->
	%% do something with head
	io:format("unknown concurix configuration ~p ~n", [Head]),
	setup_config(Tail).
