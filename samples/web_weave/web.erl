%% -*- coding: utf-8 -*-
-module(web).

%% web: weave a family tree of processes then fold it.

-export([weave/3]).


-spec weave(pos_integer(), pos_integer(), pos_integer()) -> ok.
%% Builds a perfect Arity-tree, then sends the kill signal to its lowest leaves
%%   triggering their death-timer and spreading the signal upwards.
weave(Height, Arity, Pause) ->
    process_flag(trap_exit, true), %% For spawn_link/1,3.
    io:format("Head: ~p\n", [self()]),
    Leaves = lists:flatten(
               tree(Height, [self()], Arity, Pause)),
    [Leaf ! die || Leaf <- Leaves],
    ok.



%% Internals

-spec tree(pos_integer(), [pid()], pos_integer(), pos_integer()) ->
                  list(pid()).
%% Expands vertically (of Height) given Parents.
tree(0, _, _, _) ->
    [];

tree(1, Parents, Arity, Pause) ->
    branch(Parents, Arity, Pause);

tree(Height, Parents, Arity, Pause) ->
    LoLoLeaf = branch(Parents, Arity, Pause),
    [tree(Height - 1, Leaves, Arity, Pause) || Leaves <- LoLoLeaf].


-spec branch([pid()], pos_integer(), pos_integer()) -> [[pid()]].
%% Gives Leaves (ie. a generation) their leaves (ie. direct descendance).
branch(Leaves, Arity, Pause) ->
    [leaf(Parent, Arity, Pause) || Parent <- Leaves].


-spec leaf(pid(), pos_integer(), pos_integer()) -> [pid()].
%% Gives Arity leaves to Parent leaf.
leaf(Parent, Arity, Pause) ->
    [spawn_link(fun() ->
                        who_is_who(Index, Arity, Parent),
                        loop(Parent, Pause)
                end)
     || Index <- lists:seq(1, Arity)].



-spec loop(pid(), pos_integer()) -> term().
%% Just waits for a signal to pass it and die.
loop(Parent, Pause) ->
    io:format("+"),
    receive
        _ ->
            timer:sleep(Pause), %% In µseconds!
            Parent ! die,
            io:format("-")
    end.



who_is_who(Index, Arity, Parent) ->
    io:format(case Index of
                  Arity ->
                      "<~p>,\tparent: ~p\n"; %% Highlights last leaf.
                  _ ->
                      "~p,\tparent: ~p\n"
              end,
              [self(), Parent]).


%% End of module
