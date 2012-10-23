-module(concurix_compile).
-export([string_to_form/1, handle_spawn/2]).

string_to_form(String) ->
	{ok, Tokens, _} = erl_scan:string(String),
	{ok, Forms} = erl_parse:parse_exprs(Tokens),
	Forms.
	
handle_spawn(Line, [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs]) ->
	case ets:lookup(concurix_config_spawn, {Module, Fun}) of
		[{_, Expr }] ->
			SpawnFun = {atom, Line, spawn_opt},
			SpawnOpt = "[{min_heap_size," ++ Expr ++ "}].",
			ArgsNew = [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs] ++ concurix_compile:string_to_form(SpawnOpt),
			{SpawnFun, ArgsNew};			
		_X -> 
			{{atom, Line, spawn}, [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs]}
	end;

handle_spawn(Line, Args) ->
	Fun = {atom, Line, spawn},
	{Fun, Args}.