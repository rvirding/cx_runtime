-module(concurix_compile).
-export([string_to_form/1, string_to_form/2, handle_spawn/3, get_arg_n/2, handle_memo/4, eval_string/1]).

string_to_form(String) ->
	{ok, Tokens, _} = erl_scan:string(String),
	{ok, Forms} = erl_parse:parse_exprs(Tokens),
	Forms.
	
string_to_form(String, CallArgs) ->
	Forms = string_to_form(String),
	replace_args(Forms, CallArgs).
	
	
handle_spawn(Line, [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs], Type) ->
	case ets:lookup(concurix_config_spawn, {Module, Fun}) of
		[{_, Expr }] ->
			SpawnFun = {atom, Line, spawn_opt},
			SpawnOpt = "[" ++ type_to_string(Type) ++ "{min_heap_size," ++ Expr ++ "}].",
			ArgsNew = [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs] ++ string_to_form(SpawnOpt, CallArgs),
			io:format("concurix_compile: Computed Spawn Opt for ~p:~p with expression ~p ~n",  [Module, Fun, Expr]),
			{SpawnFun, ArgsNew};			
		_X -> 
			{{atom, Line, Type}, [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs]}
	end;

%% Insert min_heap_size option into existing options.
handle_spawn(Line, [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs, Options], spawn_opt) ->
	case ets:lookup(concurix_config_spawn, {Module, Fun}) of
		[{_, Expr }] ->
			SpawnFun = {atom, Line, spawn_opt},
                        [MinHeapSize] = string_to_form("{min_heap_size," ++ Expr ++ "}.", CallArgs),
                        Options2 = store_min_heap_size(Options, MinHeapSize),
			ArgsNew = [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs, Options2],
			io:format("concurix_compile: Computed Spawn Opt for ~p:~p with expression ~p ~n",  [Module, Fun, Expr]),
			{SpawnFun, ArgsNew};			
		_X -> 
			{{atom, Line, spawn_opt}, [{atom, Line2, Module}, {atom, Line3, Fun}, CallArgs, Options]}
	end;

handle_spawn(Line, Args, Type) ->
	Fun = {atom, Line, Type},
	{Fun, Args}.


handle_memo(Line, MFLookup, Fun, Args) ->
	case ets:lookup(concurix_config_memo, MFLookup) of
		[{_, local}] ->
			io:format("concurix_compile: trying to memoize Line ~p M:F ~p ~p ~n", [Line, MFLookup, Fun]),
			generate_call_local_memo(Line, Fun, Args);
		_X -> 
			{Fun, Args}
	end.

%% Generates a pair of abstract forms representing a call to concurix_memo:local_memoize
%% and the argument to that call - a closure wrapping a call to Fun(Args).	
generate_call_local_memo(Line, Fun, Args) ->
	{{remote, Line, {atom, Line, concurix_memo}, {atom, Line, local_memoize}},
		[{'fun', Line, {clauses, [{clause, Line, [], [], [{call, Line, Fun, Args}]}]}}]}.

%% Generate a memoized call that preserves any side effects of the Args expressions.
generate_call_local_memo_with_effects(Line, Fun, Args) ->
        ArgList = generate_args(length(Args), Line),
        {{'fun', Line, {clauses,
                        [{clause, Line, ArgList, [],
                          [{call, Line,
                            {remote, Line, {atom, Line, concurix_memo}, {atom, Line, local_memoize}},
                            [{'fun', Line, {clauses,
                                            [{clause, Line, [], [],
                                              [{call, Line, Fun, ArgList}]
                                             }]
                                           }}]
                           }]
                         }]
                       }},
         Args}.

generate_args(NumArgs, Line) ->
    lists:map(fun(I) ->
                      {var, Line, list_to_atom("Arg" ++ integer_to_list(I))}
              end, lists:seq(1, NumArgs)).
	
get_arg_n(CallArgs, 1) ->
	{cons, _Line, Arg, _Remainder} = CallArgs,
	Arg;
get_arg_n(CallArgs, N) ->
	{cons, _Line, _Arg, Remainder} = CallArgs,
	get_arg_n(Remainder, N-1).

%% If it's the kind of record I'm looking for, replace it.
replace_args({call, _, {atom, _, arg}, [{integer, _, Index}]}, CallArgs) ->
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

type_to_string(Type) ->
	case Type of
		spawn -> "";
		spawn_link -> "link,";
                spawn_monitor ->"monitor,";
                spawn_opt -> ""
	end.
	
%% Take a list of spawn options in abstract format, remove any existing min_heap_size
%% option and add a new one.
store_min_heap_size({nil, Line}, MinHeapSize) ->
    {cons, Line, MinHeapSize, {nil, Line}};
store_min_heap_size({cons, _Line, {tuple, _Line2, [{atom, _Line3, min_heap_size}, _Size]}, Tail}, MinHeapSize) ->
    store_min_heap_size(Tail, MinHeapSize);
store_min_heap_size({cons, Line, Head, Tail}, MinHeapSize) ->
    {cons, Line, Head, store_min_heap_size(Tail, MinHeapSize)}.

%%
%% some helper functions
eval_string(String) ->
    {ok, Tokens, _} = erl_scan:string(lists:concat([String, "."])),
    {_Status, Term} = erl_parse:parse_term(Tokens),
	Term.

