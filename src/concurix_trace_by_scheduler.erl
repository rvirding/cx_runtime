-module(concurix_trace_by_scheduler).

-behaviour(gen_server).

-export([start/1]).
-export([handle_system_profile/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start(SysProfTable) ->
  %%
  %% This is to become the gen-server that will collect system info and write to the SysProf ETS table
  %%  
        
  SysProfPid = spawn_link(?MODULE, handle_system_profile, [SysProfTable]),
  erlang:system_profile(SysProfPid, [concurix]).


%%
%% The Concurix system profiler
%%
%% Each scheduler sends a message at a standard interval, currently every 2 seconds, 
%% that provides a snapshot of the activity that occured during the most recent interval (window).
%% 
%% The Stats element is the tuple
%%     'concurix',
%%     number of processes created
%%     number of quanta executed
%%     total quanta time (us)
%%     number of messages send
%%     number of GCs performed
%%     number of true calls performed
%%     number of tail calls performed
%%     number of returns executed
%%     number of processes that exited
%%
%% The message also indicates the start/end time for the sample
%%
 
handle_system_profile(SysProfTable) ->
  receive
    { profile, concurix, SchedulerId,  SchedulerStats, WindowStart, WindowStop } ->
      ets:insert(SysProfTable, {SchedulerId, {SchedulerStats, WindowStart, WindowStop}}),
      handle_system_profile(SysProfTable);

    Other ->
      io:format("OTHER:    ~p~n", [Other]),
      handle_system_profile(SysProfTable)
  end.
 

%%
%% gen_server support
%%

init([_Config]) ->
  ok.

handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.
