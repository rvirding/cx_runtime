-module(concurix_cpu_info).

-export([load_avg/0, cpu_info/0]).

load_avg() ->
    [cpu_sup:avg1() / 256, cpu_sup:avg5() / 256, cpu_sup:avg15() / 256].

cpu_info() ->
    case os:type() of
        {unix, _} ->
            RawInfo = re:split(os:cmd("cat /proc/cpuinfo"), "\n"),
            CpuInfos = group_cpus(parse_cpu_fields(RawInfo)),
            CpuTimes = cpu_times(),
            [[{times, proplists:get_value(proplists:get_value(id, CpuInfo), CpuTimes)} | CpuInfo] || CpuInfo <- CpuInfos];
        _ ->
            % erlang has no way of retrieving cpu info on windows :(
            []
    end.

cpu_times() ->
    [{Id, [{busy, Busy}, {nonbusy, NonBusy}, {misc, Misc}]} || {Id, Busy, NonBusy, Misc} <- cpu_sup:util([detailed, per_cpu])].

parse_cpu_fields(RawInfo) ->
    parse_cpu_fields(RawInfo, []).

parse_cpu_fields([], Fields) ->
    Fields;
parse_cpu_fields([<<>> | Lines], Fields) ->
    parse_cpu_fields(Lines, Fields);
parse_cpu_fields([Line | Lines], Fields) ->
    Field =
        case re:split(Line, "\t*: ?") of
            [Key] -> parse_cpu_field(Key, <<"">>);
            [Key, Value] -> parse_cpu_field(Key, Value)
        end,
    parse_cpu_fields(Lines, Field ++ Fields).

parse_cpu_field(<<"processor">>, Value) ->
    [{id, list_to_integer(binary_to_list(Value))}];
parse_cpu_field( <<"model name">>, Value) ->
    [{model, Value}];
parse_cpu_field(<<"cpu MHz">>, Value) ->
    [{speed, list_to_float(binary_to_list(Value))}];
parse_cpu_field(_, _) ->
    []. % TODO handle other fields

group_cpus(Fields) ->
    group_cpus(Fields, [], []).

group_cpus([], [], Cpus) -> % {id, _} is always at the end of the list so Cpu should be empty
    Cpus;
group_cpus([Field = {id, _Id} | Fields], Cpu, Cpus) ->
    group_cpus(Fields, [], [[Field | Cpu] | Cpus]);
group_cpus([Field | Fields], Cpu, Cpus) ->
    group_cpus(Fields, [Field | Cpu], Cpus).
