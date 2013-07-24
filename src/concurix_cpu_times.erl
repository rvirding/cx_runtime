%% ---------- mostly copied from cpu_sup ----------

%% Copyright Ericsson AB 1997-2009. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.%% Internal protocol with the port program

-module(concurix_cpu_times).

-export([get_load_avg/0, get_cpu_times/0]).
-export([start_link/0]).

-define(SERVER, ?MODULE).

-define(nprocs,"n").
-define(avg1,"1").
-define(avg5,"5").
-define(avg15,"f").
-define(quit,"q").
-define(ping,"p").
-define(util,"u").

-define(cu_cpu_id, 0).
-define(cu_user, 1).
-define(cu_nice_user, 2).
-define(cu_kernel, 3).
-define(cu_io_wait, 4).
-define(cu_idle, 5).
-define(cu_hard_irq, 6).
-define(cu_soft_irq, 7).
-define(cu_steal, 8).

-record(cpu_util, {cpu, busy = [], non_busy = []}).

-define(INT32(D3,D2,D1,D0),
        (((D3) bsl 24) bor ((D2) bsl 16) bor ((D1) bsl 8) bor (D0))).

-define(MAX_UINT32, ((1 bsl 32) - 1)).

get_load_avg() ->
    {ok,F} = file:open("/proc/loadavg",[read,raw]),
    {ok,D} = file:read(F,24),
    ok = file:close(F),
    {ok,[Load1,Load5,Load15,_PRun,_PTotal],_} = io_lib:fread("~f ~f ~f ~d/~d", D),
    [Load1, Load5, Load15].

get_cpu_times() ->
    [{Id, [{user, proplists:get_value(user, Busy)},
           {nice, proplists:get_value(nice_user, Busy)},
           {sys, proplists:get_value(kernel, Busy)},
           {idle, proplists:get_value(idle, NonBusy) + proplists:get_value(wait, NonBusy) + proplists:get_value(steal, NonBusy)},
           {irq, proplists:get_value(soft_irq, Busy) + proplists:get_value(hard_irq, Busy)}]}
     || {cpu_util, Id, Busy, NonBusy} <- port_server_call(whereis(?SERVER), ?util, 1000)].

start_link() ->
    Timeout = 6000,
    Pid = spawn_link(fun() -> port_server_init(Timeout) end),
    Pid ! {self(), ?ping},
    receive
        {Pid, {data,4711}} -> {ok, Pid};
        {error,Reason} -> {error, Reason}
    after Timeout ->
            {error, timeout}
    end.

port_server_call(Pid, Command, Timeout) ->
    Pid ! {self(), Command},
    receive
        {Pid, {data, Result}} -> Result;
        {Pid, {error, Reason}} -> {error, Reason}
    after Timeout ->
        {error, timeout}
    end.

port_server_init(Timeout) ->
    Port = start_portprogram(),
    register(?SERVER, self()),
    port_server_loop(Port, Timeout).

port_server_loop(Port, Timeout) ->
    receive

                                                % Adjust timeout
        {Pid, {timeout, Timeout}} ->
            Pid ! {data, Timeout},
            port_server_loop(Port, Timeout);
                                                % Number of processors
        {Pid, ?nprocs} ->
            port_command(Port, ?nprocs),
            Result = port_receive_uint32(Port, Timeout),
            Pid ! {self(), {data, Result}},
            port_server_loop(Port, Timeout);

                                                % Average load for the past minute
        {Pid, ?avg1} ->
            port_command(Port, ?avg1),
            Result = port_receive_uint32(Port, Timeout),
            Pid ! {self(), {data, Result}},
            port_server_loop(Port, Timeout);

                                                % Average load for the past five minutes
        {Pid, ?avg5} ->
            port_command(Port, ?avg5),
            Result = port_receive_uint32(Port, Timeout),
            Pid ! {self(), {data, Result}},
            port_server_loop(Port, Timeout);

                                                % Average load for the past 15 minutes
        {Pid, ?avg15} ->
            port_command(Port, ?avg15),
            Result = port_receive_uint32(Port, Timeout),
            Pid ! {self(), {data, Result}},
            port_server_loop(Port, Timeout);

        {Pid, ?util} ->
            port_command(Port, ?util),
            Result = port_receive_util(Port, Timeout),
            Pid ! {self(), {data, Result}},
            port_server_loop(Port, Timeout);

                                                % Port ping
        {Pid, ?ping} ->
            port_command(Port, ?ping),
            Result = port_receive_uint32(Port, Timeout),
            Pid ! {self(), {data, Result}},
            port_server_loop(Port, Timeout);

                                                % Close port and this server
        {Pid, ?quit} ->
            port_command(Port, ?quit),
            port_close(Port),
            Pid ! {self(), {data, quit}},
            ok;

                                                % Ignore other commands
        _ -> port_server_loop(Port, Timeout)
    end.

port_receive_uint32( Port, Timeout) -> port_receive_uint32(Port, Timeout, []).
port_receive_uint32(_Port, _Timeout, [D3,D2,D1,D0]) -> ?INT32(D3,D2,D1,D0);
port_receive_uint32(_Port, _Timeout, [_,_,_,_ | G]) -> exit({port_garbage, G});
port_receive_uint32(Port, Timeout, D) ->
    receive
        {'EXIT', Port, Reason} -> exit({port_exit, Reason});
        {Port, {data, ND}} -> port_receive_uint32(Port, Timeout, D ++ ND)
    after Timeout -> exit(timeout_uint32) end.

port_receive_util(Port, Timeout) ->
    receive
        {Port, {data, [ NP3,NP2,NP1,NP0, % Number of processors
                        NE3,NE2,NE1,NE0 % Number of entries per processor
                        | CpuData]}} ->
            port_receive_cpu_util( ?INT32(NP3,NP2,NP1,NP0),
                                   ?INT32(NE3,NE2,NE1,NE0),
                                   CpuData, []);
        {'EXIT', Port, Reason} -> exit({port_exit, Reason})
    after Timeout -> exit(timeout_util) end.

% per processor receive loop
port_receive_cpu_util(0, _NE, [], CpuList) ->
% Return in ascending cpu_id order
    lists:reverse(CpuList);
port_receive_cpu_util(0, _NE, Garbage, _) ->
    exit( {port_garbage, Garbage});
port_receive_cpu_util(NP, NE, CpuData, CpuList) ->
    {CpuUtil, Rest} = port_receive_cpu_util_entries(NE, #cpu_util{}, CpuData),
    port_receive_cpu_util(NP - 1, NE, Rest, [ CpuUtil | CpuList]).

% per entry receive loop
port_receive_cpu_util_entries(0, CU, Rest) ->
    {CU, Rest};
port_receive_cpu_util_entries(NE, CU,
                              [ CID3, CID2, CID1, CID0,
                                Val3, Val2, Val1, Val0 |
                                CpuData]) ->

    TagId = ?INT32(CID3,CID2,CID1,CID0),
    Value = ?INT32(Val3,Val2,Val1,Val0),

    % Conversions from integers to atoms
    case TagId of
        ?cu_cpu_id ->
            NewCU = CU#cpu_util{cpu = Value},
            port_receive_cpu_util_entries(NE - 1, NewCU, CpuData);
        ?cu_user ->
            NewCU = CU#cpu_util{
                      busy = [{user, Value} | CU#cpu_util.busy] },
            port_receive_cpu_util_entries(NE - 1, NewCU, CpuData);
        ?cu_nice_user ->
            NewCU = CU#cpu_util{
                      busy = [{nice_user, Value} | CU#cpu_util.busy] },
            port_receive_cpu_util_entries(NE - 1, NewCU, CpuData);
        ?cu_kernel ->
            NewCU = CU#cpu_util{
                      busy = [{kernel, Value} | CU#cpu_util.busy] },
            port_receive_cpu_util_entries(NE - 1, NewCU, CpuData);
        ?cu_io_wait ->
            NewCU = CU#cpu_util{
                      non_busy = [{wait, Value} | CU#cpu_util.non_busy] },
            port_receive_cpu_util_entries(NE - 1, NewCU, CpuData);
        ?cu_idle ->
            NewCU = CU#cpu_util{
                      non_busy = [{idle, Value} | CU#cpu_util.non_busy] },
            port_receive_cpu_util_entries(NE - 1, NewCU, CpuData);
        ?cu_hard_irq ->
            NewCU = CU#cpu_util{
                      busy = [{hard_irq, Value} | CU#cpu_util.busy] },
            port_receive_cpu_util_entries(NE - 1, NewCU, CpuData);
        ?cu_soft_irq ->
            NewCU = CU#cpu_util{
                      busy = [{soft_irq, Value} | CU#cpu_util.busy] },
            port_receive_cpu_util_entries(NE - 1, NewCU, CpuData);
        ?cu_steal ->
            NewCU = CU#cpu_util{
                      non_busy = [{steal, Value} | CU#cpu_util.non_busy] },
            port_receive_cpu_util_entries(NE - 1, NewCU, CpuData);
        Unhandled ->
            exit({unexpected_type_id, Unhandled})
    end;
port_receive_cpu_util_entries(_, _, Data) ->
    exit({data_mismatch, Data}).

start_portprogram() ->
    Command = filename:join([code:priv_dir(os_mon), "bin", "cpu_sup"]),
    Port = open_port({spawn, Command}, [stream]),
    port_command(Port, ?ping),
    4711 = port_receive_uint32(Port, 5000),
    Port.
