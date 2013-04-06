
%% A simple program with an exagerrated bottleneck.

-module(bottleneck).

-export([start/1, phase1/1, alarm/1]).

-spec start(integer()) -> ok.
start(N) ->
    case whereis(fast_alarm) of
        undefined ->
            register(fast_alarm, spawn(bottleneck, alarm, [10]));
        _ ->
            ok
    end,

    case whereis(slow_alarm) of
        undefined ->
            register(slow_alarm, spawn(bottleneck, alarm, [1000]));
        _ ->
            ok
    end,

    _Pids = lists:map(fun(I) ->
                              spawn(bottleneck, phase1, [I])
                      end, lists:seq(1, N)),
    ok.


-spec phase1(integer()) -> ok.
phase1(I) ->
    io:format("Start phase1(~b)~n", [I]),
    phase2(I).

-spec phase2(integer()) -> ok.
phase2(I) ->
    io:format("Start phase2(~b)~n", [I]),
    slow_alarm ! {self(), wake_me},
    receive
        wake_up ->
            io:format("End phase2(~b)~n", [I]),
            ok
    end.

-spec alarm(integer()) -> ok.
alarm(WaitTime) ->
    receive
        {Pid, wake_me} ->
            Pid ! wake_up,
            timer:sleep(WaitTime),
            alarm(WaitTime)
    end.
