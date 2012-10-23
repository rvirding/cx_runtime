-module(concurix_compile).
-export([string_to_form/1, string_to_form/2, handle_spawn/2, get_arg_n/2]).

string_to_form(String) ->
	{ok, Tokens, _} = erl_scan:string(String),
	{ok, Forms} = erl_parse:parse_exprs(Tokens),
	Forms.
	
string_to_form(String, CallArgs) ->
	Forms = string_to_form(String),
	replace_args(Forms, CallArgs).
	
	
handle_spawn(Line, [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs]) ->
	case ets:lookup(concurix_config_spawn, {Module, Fun}) of
		[{_, Expr }] ->
			SpawnFun = {atom, Line, spawn_opt},
			SpawnOpt = "[{min_heap_size," ++ Expr ++ "}].",
			ArgsNew = [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs] ++ string_to_form(SpawnOpt, CallArgs),
			io:format("Args New ~p ~n CallArgs ~p ~n", [ArgsNew, CallArgs]),
			{SpawnFun, ArgsNew};			
		_X -> 
			{{atom, Line, spawn}, [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs]}
	end;

handle_spawn(Line, Args) ->
	Fun = {atom, Line, spawn},
	{Fun, Args}.
	
get_arg_n(CallArgs, 1) ->
	{cons, _Line, Arg, _Remainder} = CallArgs,
	Arg;
get_arg_n(CallArgs, N) ->
	{cons, _Line, _Arg, Remainder} = CallArgs,
	get_arg_n(Remainder, N-1).

%% If it's the kind of record I'm looking for, replace it.
replace_args({call, _, {atom, _, arg}, [{integer, _, Index}]}, CallArgs) ->
	io:format("got arg call for index ~p ~n", [Index]),
	get_arg_n(CallArgs, Index);

%% If it's a list, recurse into the head and tail
replace_args([Hd|Tl], CallArgs) ->
    [replace_args(Hd, CallArgs)|replace_args(Tl, CallArgs)];

%% If it's a tuple, which of course includes records, recurse into the
%% fields
replace_args(Tuple, CallArgs) when is_tuple(Tuple) ->
    list_to_tuple([replace_args(E, CallArgs) || E <- tuple_to_list(Tuple)]);

%% Otherwise, return the original.
replace_args(Leaf, _CallArgs) ->
    Leaf.


