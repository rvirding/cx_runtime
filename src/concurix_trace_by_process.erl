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
  erlang:trace(all, true, [procs, send, running, scheduler_id]),

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
handle_info({trace, Creator, spawn, Pid, Data}, State) ->
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
  Key        = {Pid, {Mod, Fun, Arity}, Service, 1, Behaviour},

  ets:insert(State#tcstate.processTable, Key),

  %% also include a link from the creator process to the created.
  update_proc_table(Creator, State),

  %% TODO--should probably remove this once we put in supervisor hierarchy support
  ets:insert(State#tcstate.linkTable, {{Creator, Pid}, 1, 0}),
  {noreply, State};

handle_info({trace, Pid, exit, _Reason}, State) ->
  ets:safe_fixtable(State#tcstate.processTable,   true),
  ets:safe_fixtable(State#tcstate.linkTable,      true),
  ets:safe_fixtable(State#tcstate.procLinkTable,  true),

  ets:select_delete(State#tcstate.linkTable,       [ { {{'_', Pid}, '_', '_'},    [], [true] }, 
                                                     { {{Pid, '_'}, '_', '_'},    [], [true] } ]),

  ets:select_delete(State#tcstate.processTable,    [ { {Pid, '_', '_', '_', '_'}, [], [true] } ]),

  ets:select_delete(State#tcstate.procLinkTable,   [ { {'_', Pid},                [], [true] }, 
                                                     { {Pid, '_'},                [], [true] } ]),

  ets:safe_fixtable(State#tcstate.linkTable,     false),
  ets:safe_fixtable(State#tcstate.processTable,  false),
  ets:safe_fixtable(State#tcstate.procLinkTable, false),

  {noreply, State};


%%
%% These messages are sent when a Process is started/stopped on a given scheduler
%%

handle_info({trace, Pid, in,  Scheduler, _MFA}, State) ->
  update_proc_scheduler(Pid, Scheduler, State),
  {noreply, State};

handle_info({trace, Pid, out, Scheduler, _MFA}, State) ->
  update_proc_scheduler(Pid, Scheduler, State),
  {noreply, State};


%%
%% Track messages sent
%%
handle_info({trace, Sender, send, Data, Recipient}, State) ->
  update_proc_table(Sender,    State),
  update_proc_table(Recipient, State),

  Size = erts_debug:flat_size(Data),
  
  case ets:lookup(State#tcstate.linkTable, {Sender, Recipient}) of
    [] ->
      ets:insert(State#tcstate.linkTable, {{Sender, Recipient}, 1, Size});

    _ ->
      ets:update_counter(State#tcstate.linkTable, {Sender, Recipient}, [{2, 1}, {3, Size}])
  end, 

  {noreply, State};


%%
%% MDN It's surprising that this is happening in compiled Mandelbrot
%%
handle_info({trace, _Pid,  send_to_non_existing_process, _Msg, _To}, State) ->
  {noreply, State};


handle_info({trace, Pid, getting_linked,   Pid2}, State) ->
  insert_proc_link(State, Pid, Pid2),
  {noreply, State};

handle_info({trace, Pid, getting_unlinked, Pid2}, State) ->
  delete_proc_link(State, Pid, Pid2),
  {noreply, State};

handle_info({trace, Pid, link,             Pid2}, State) ->
  insert_proc_link(State, Pid, Pid2),
  {noreply, State};

handle_info({trace, Pid, unlink,           Pid2}, State) ->
  delete_proc_link(State, Pid, Pid2),
  {noreply, State};

handle_info({trace, _Pid, register,         _Srv},  State) ->
  {noreply, State};

handle_info(stop_tracing,                           State) ->
  erlang:trace(all, false, []),
  {noreply, State};

handle_info(Msg,                                    State) ->
  io:format("~p:handle_info/2.  Unsupported msg = ~p ~n", [?MODULE, Msg]),
  {noreply, State}.

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
      [{Pid, {Mod, Fun, Arity}, Service, Scheduler, Behaviour}] = concurix_runtime:update_process_info(Pid),
      ets:insert(State#tcstate.processTable, {Pid, {Mod, Fun, Arity}, Service, Scheduler, Behaviour});

    _ ->
      ok
  end.

update_proc_scheduler(Pid, Scheduler, State) ->
  case ets:lookup(State#tcstate.processTable, Pid) of 
    [] ->
      %% we don't have it yet, wait until we get the create message
      ok;

    [{Pid, {Mod, Fun, Arity}, Service, _OldScheduler, Behaviour}] ->
      ets:insert(State#tcstate.processTable, {Pid, {Mod, Fun, Arity}, Service, Scheduler, Behaviour});

    X ->
      io:format("yikes, corrupt proc table ~p ~n", [X])
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
