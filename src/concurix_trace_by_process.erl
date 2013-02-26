-module(concurix_trace_by_process).

-behaviour(gen_server).

-export([start_link/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(ctbp_state, { processTable, linkTable }).

start_link(Procs, Links) ->
  gen_server:start_link(?MODULE, [Procs, Links], []).

init([Procs, Links]) ->
%%  io:format("concurix_trace_by_process:init/2                         ~p~n", [self()]),


  %% This gen_server will receive the trace messages (i.e. invoke handle_info/2)
  erlang:trace(all, true, [procs, send, running, scheduler_id]),

  {ok, #ctbp_state{processTable = Procs, linkTable = Links}}.

handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
terminate(_Reason, _State) ->
  dbg:stop_clear(),
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

  Service = concurix_runtime:mod_to_service(Mod),
  Key     = {Pid, {Mod, Fun, Arity}, Service, 0},

  ets:insert(State#ctbp_state.processTable, Key),

  %% also include a link from the creator process to the created.
  update_proc_table(Creator, State),
  ets:insert(State#ctbp_state.linkTable, {{Creator, Pid}, 1}),
  {noreply, State};

handle_info({trace, Pid, exit, _Reason}, State) ->
  ets:safe_fixtable(State#ctbp_state.processTable, true),
  ets:safe_fixtable(State#ctbp_state.linkTable,    true), 

  ets:select_delete(State#ctbp_state.linkTable,    [ { {{'_', Pid}, '_'}, [], [true]}, 
                                                  { {{Pid, '_'}, '_'}, [], [true] } ]),
  ets:select_delete(State#ctbp_state.processTable, [ { {Pid, '_', '_', '_'}, [], [true]}]),

  ets:safe_fixtable(State#ctbp_state.linkTable,    false),  
  ets:safe_fixtable(State#ctbp_state.processTable, false), 

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
handle_info({trace, Sender, send, _Data, Recipient}, State) ->
  update_proc_table(Sender,    State),
  update_proc_table(Recipient, State),

  case ets:lookup(State#ctbp_state.linkTable, {Sender, Recipient}) of
    [] ->
      ets:insert(State#ctbp_state.linkTable, {{Sender, Recipient}, 1});

    _ ->
      ets:update_counter(State#ctbp_state.linkTable, {Sender, Recipient}, 1)
  end, 

  {noreply, State};


%%
%% These messages are ignored
%%
handle_info({trace, _Pid, getting_linked,   _Pid2}, State) ->
  {noreply, State};

handle_info({trace, _Pid, getting_unlinked, _Pid2}, State) ->
  {noreply, State};

handle_info({trace, _Pid, link,             _Pid2}, State) ->
  {noreply, State};

handle_info({trace, _Pid, unlink,           _Pid2}, State) ->
  {noreply, State};

handle_info({trace, _Pid, register,         _Srv},  State) ->
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
  case ets:lookup(State#ctbp_state.processTable, Pid) of
    [] ->
      [{Pid, {Mod, Fun, Arity}, Service}] = concurix_runtime:update_process_info(Pid),
      ets:insert(State#ctbp_state.processTable, {Pid, {Mod, Fun, Arity}, Service, 0});

    _ ->
      ok
  end.

update_proc_scheduler(Pid, Scheduler, State) ->
  case ets:lookup(State#ctbp_state.processTable, Pid) of 
    [] ->
      %% we don't have it yet, wait until we get the create message
      ok;

    [{Pid, {Mod, Fun, Arity}, Service, _OldScheduler}] ->
      ets:insert(State#ctbp_state.processTable, {Pid, {Mod, Fun, Arity}, Service, Scheduler});

    X ->
      io:format("yikes, corrupt proc table ~p ~n", [X])
  end.


