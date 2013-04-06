%% %CopyrightBegin%
%%
%% Copyright Concurix Corporation 2012-2013. All Rights Reserved.
%%
%% The contents of this file are subject to the Concurix Terms of Service:
%% http://www.concurix.com/main/tos_main
%%
%% The Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. 
%%
%% %CopyrightEnd%
%%
%% This gen_server handles all of the functionality for hooking into Erlang:trace
%%
-module(concurix_trace_by_process).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("concurix_runtime.hrl").

start_link(State) ->
  gen_server:start_link(?MODULE, [State], []).

init([State]) ->
  %% This gen_server will receive the trace messages (i.e. invoke handle_info/2)
  erlang:trace(all, true, [procs, send, running, scheduler_id, timestamp]),

  {ok, State}.

handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
terminate(_Reason, _State) ->
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.
 
%%
%% This gen_server will receive the trace messages 
%%
%% Handle process creation and destruction
%%
handle_info({trace, Creator, spawn, Pid,               Data}, State) ->
  {noreply, trace_spawn(Creator, Pid, Data, undefined, State)};
handle_info({trace_ts, Creator, spawn, Pid, Data, TimeStamp}, State) ->
  {noreply, trace_spawn(Creator, Pid, Data, TimeStamp, State)};


handle_info({trace, Pid, exit,               Reason}, State) ->
  trace_exit(Pid, Reason, undefined, State),
  {noreply, State};  
handle_info({trace_ts, Pid, exit, Reason, TimeStamp}, State) ->
  trace_exit(Pid, Reason, TimeStamp, State),
  {noreply, State};  


%%
%% These messages are sent when a Process is started/stopped on a given scheduler
%%

handle_info({trace, Pid, in,  Scheduler,               _MFA}, State) ->
  update_proc_scheduler(Pid, Scheduler, undefined, State),
  {noreply, State};
handle_info({trace_ts, Pid, in,  Scheduler, MFA, TimeStamp}, State) ->
  update_proc_scheduler(Pid, Scheduler, TimeStamp, State),
  update_event_times(Pid, MFA, TimeStamp, State),
  {noreply, State};  

handle_info({trace, Pid, out, Scheduler,               _MFA}, State) ->
  update_proc_scheduler(Pid, Scheduler, undefined, State),
  {noreply, State};
handle_info({trace_ts, Pid, out, Scheduler, _MFA, TimeStamp}, State) ->
  update_proc_scheduler(Pid, Scheduler, TimeStamp, State),
  {noreply, State};

%%
%% Track messages sent
%%
handle_info({trace, Sender, send, Data,               Recipient}, State) ->
  {noreply, trace_send(Sender, Data, Recipient, undefined, State)};
handle_info({trace_ts, Sender, send, Data, Recipient, TimeStamp}, State) ->
  {noreply, trace_send(Sender, Data, Recipient, TimeStamp, State)};


%%
%% MDN It's surprising that this is happening in compiled Mandelbrot
%%
handle_info({trace, _Pid,  send_to_non_existing_process, _Msg,                _To}, State) ->
  {noreply, State};
handle_info({trace_ts, _Pid,  send_to_non_existing_process, _Msg, _To, _TimeStamp}, State) ->
  {noreply, State};


handle_info({trace, Pid, getting_linked,                Pid2}, State) ->
  insert_proc_link(State, Pid, Pid2),
  {noreply, State};
handle_info({trace_ts, Pid, getting_linked, Pid2, _TimeStamp}, State) ->
  insert_proc_link(State, Pid, Pid2),
  {noreply, State};

handle_info({trace, Pid, getting_unlinked,               Pid2}, State) ->
  delete_proc_link(State, Pid, Pid2),
  {noreply, State};
handle_info({trace_ts, Pid, getting_unlinked, Pid2, _TimeStamp}, State) ->
  delete_proc_link(State, Pid, Pid2),
  {noreply, State};

handle_info({trace, Pid, link,                 Pid2}, State) ->
  insert_proc_link(State, Pid, Pid2),
  {noreply, State};
handle_info({trace_ts, Pid, link, Pid2,  _TimeStamp}, State) ->
  insert_proc_link(State, Pid, Pid2),
  {noreply, State};

handle_info({trace, Pid, unlink,               Pid2}, State) ->
  delete_proc_link(State, Pid, Pid2),
  {noreply, State};
handle_info({trace_ts, Pid, unlink, Pid2, _TimeStamp}, State) ->
  delete_proc_link(State, Pid, Pid2),
  {noreply, State};

handle_info({trace, _Pid, register,                _Srv},  State) ->
  {noreply, State};
handle_info({trace_ts, _Pid, register, _Srv, _TimeStamp},  State) ->
  {noreply, State};

handle_info(stop_tracing,                           State) ->
  erlang:trace(all, false, []),
  {stop, normal, State};

handle_info(Msg,                                    State) ->
  io:format("~p:handle_info/2.  Unsupported msg = ~p ~n", [?MODULE, Msg]),
  {noreply, State}.


trace_spawn(Creator, Pid, Data, TimeStamp, State) ->
  case Data of 
    {proc_lib, init_p, _ProcInfo} ->
      {Mod, Fun, Arity} = concurix_runtime:local_translate_initial_call(Pid),
      ok;

    {erlang, apply, [TempFun, _Args]} ->
      {Mod, Fun, Arity} = decode_anon_fun(TempFun);

    {Mod, Fun, Args} ->
      Arity = length(Args),
      ok;

    X ->
      %%io:format("got unknown spawn of ~p ~n", [X]),
      Mod   = unknown,
      Fun   = X,
      Arity = 0
  end,

  Service   = concurix_runtime:mod_to_service(Mod),
  Behaviour = concurix_runtime:mod_to_behaviour(Mod),
  Number    = State#tcstate.processCounter + 1,
  State1    = State#tcstate{processCounter = Number},
  Key       = {Pid, {Mod, Fun, Arity}, Service, 1, Behaviour, Number, TimeStamp},

  ets:insert(State1#tcstate.processTable, Key),

  %% also include a link from the creator process to the created.
  State2 = update_proc_table(Creator, State1),

  %% TODO--should probably remove this once we put in supervisor hierarchy support
  ets:insert(State2#tcstate.linkTable, {{Creator, Pid}, 1, 0}),

  State2.


trace_exit(Pid, _Reason, _TimeStamp, State) ->
  ets:safe_fixtable(State#tcstate.processTable,   true),
  ets:safe_fixtable(State#tcstate.linkTable,      true),
  ets:safe_fixtable(State#tcstate.procLinkTable,  true),

  ets:select_delete(State#tcstate.linkTable,       [ { {{'_', Pid}, '_', '_'},         [], [true] }, 
                                                     { {{Pid, '_'}, '_', '_'},         [], [true] } ]),

  ets:select_delete(State#tcstate.processTable,    [ { {Pid, '_', '_', '_', '_', '_', '_'}, [], [true] } ]),

  ets:select_delete(State#tcstate.procLinkTable,   [ { {'_', Pid},                     [], [true] }, 
                                                     { {Pid, '_'},                     [], [true] } ]),

  ets:safe_fixtable(State#tcstate.linkTable,     false),
  ets:safe_fixtable(State#tcstate.processTable,  false),
  ets:safe_fixtable(State#tcstate.procLinkTable, false).


trace_send(Sender, Data, Recipient, _TimeStamp, State) ->
  State1 = update_proc_table(Sender,    State),
  State2 = update_proc_table(Recipient, State1),

  Size = erts_debug:flat_size(Data),
  
  case ets:lookup(State2#tcstate.linkTable, {Sender, Recipient}) of
    [] ->
      ets:insert(State2#tcstate.linkTable, {{Sender, Recipient}, 1, Size});

    _ ->
      ets:update_counter(State2#tcstate.linkTable, {Sender, Recipient}, [{2, 1}, {3, Size}])
  end,
  State2.


decode_anon_fun(Fun) ->
  Str = lists:flatten(io_lib:format("~p", [Fun])),

  case string:tokens(Str, "<") of
    ["#Fun", Name] ->
      [Mod | _] = string:tokens(Name, ".");

    _ ->
      Mod = "anon_function"
  end,

  {Mod, Str, 0}.
 
update_proc_table(Pid, State) ->
  case ets:lookup(State#tcstate.processTable, Pid) of
    [] ->
      Number = State#tcstate.processCounter + 1,
      [{Pid, {Mod, Fun, Arity}, Service, Scheduler, Behaviour}] =
              concurix_runtime:update_process_info(Pid),
      ets:insert(State#tcstate.processTable, {Pid, {Mod, Fun, Arity}, Service, Scheduler, Behaviour, Number, now()}),
      State#tcstate{processCounter = Number};

    _ ->
      State
  end.

update_proc_scheduler(Pid, Scheduler, _TimeStamp, State) ->
  case ets:lookup(State#tcstate.processTable, Pid) of 
    [] ->
      %% we don't have it yet, wait until we get the create message
      ok;

    [{Pid, {Mod, Fun, Arity}, Service, _OldScheduler, Behaviour, Number, StartTime}] ->
      ets:insert(State#tcstate.processTable, {Pid, {Mod, Fun, Arity}, Service, Scheduler, Behaviour, Number, StartTime});

    X ->
      io:format("yikes, corrupt proc table in update_proc_scheduler ~p ~n", [X])
  end.

update_event_times(Pid, MFA, TimeStamp, State) ->
  EventTimeTable = State#tcstate.eventTimeTable,

  case ets:lookup(State#tcstate.processTable, Pid) of
    [{Pid, _, _, _, _, Number, StartTime}] ->
      X = Number,
      Y = timer:now_diff(TimeStamp, StartTime),
    
      case ets:lookup(EventTimeTable, MFA) of
        [] ->
          ets:insert(EventTimeTable, {MFA, 1, X, Y, X * X, Y * Y, X * Y});

        [{MFA, N, SumX, SumY, SumXSquared, SumYSquared, SumXY}] ->
          ets:insert(EventTimeTable, {MFA, N + 1, SumX + X, SumY + Y,
                                      SumXSquared + X * X, SumYSquared + Y * Y,
                                      SumXY + X * Y});

        X ->
          io:format("yikes, corrupt proc table in update_event_times ~p ~n", [X])
      end;
    _ ->
      ok
  end.

insert_proc_link(State, Pid1, Pid2) when Pid1 < Pid2; is_pid(Pid1); is_pid(Pid2) ->
  ets:insert(State#tcstate.procLinkTable, {Pid1, Pid2});
insert_proc_link(State, Pid1, Pid2) when is_pid(Pid1); is_pid(Pid2)->
  ets:insert(State#tcstate.procLinkTable, {Pid2, Pid1});
insert_proc_link(_State, _Pid1, _Pid2) ->
  ok.
  
delete_proc_link(State, Pid1, Pid2) when Pid1 < Pid2; is_pid(Pid1); is_pid(Pid2) ->
  ets:delete_object(State#tcstate.procLinkTable, {Pid1, Pid2});
delete_proc_link(State, Pid1, Pid2) when is_pid(Pid1); is_pid(Pid2)->
  ets:delete_object(State#tcstate.procLinkTable, {Pid2, Pid1});
delete_proc_link(_State, _Pid1, _Pid2) ->
  ok.
