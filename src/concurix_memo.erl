-module(concurix_memo).
-export([local_memoize/1]).

local_memoize(F) when is_function(F) ->
	case get(F) of 
		undefined ->
			%%io:format("memoize: storing results for the first time for ~p ~n", [F]),
			Ret = F(),
			put(F,Ret),
			Ret;
		X -> 
			%%io:format("got a stored result! ~p ~n", [X]),
			X
	end.
			