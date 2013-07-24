-module(concurix_cpu_info).

-export([get_cpu_info/0]).

get_cpu_info() ->
    case os:type() of
        {unix, linux} ->
            RawInfo = re:split(os:cmd("cat /proc/cpuinfo"), "\n"),
            group_cpus(parse_cpu_fields(RawInfo));
        _ ->
            % erlang has no way of retrieving cpu info on windows :(
            []
    end.

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
    []. % ignore other fields for now

group_cpus(Fields) ->
    group_cpus(Fields, [], []).

group_cpus([], [], Cpus) -> % {id, _} is always at the end of the list so Cpu should be empty
    Cpus;
group_cpus([Field = {id, _Id} | Fields], Cpu, Cpus) ->
    group_cpus(Fields, [], [[Field | Cpu] | Cpus]);
group_cpus([Field | Fields], Cpu, Cpus) ->
    group_cpus(Fields, [Field | Cpu], Cpus).
