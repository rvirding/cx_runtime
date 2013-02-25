-module(concurix_send_to_viz).

-behaviour(gen_server).

-export([start/1]).
-export([send_summary/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TIMER_INTERVAL_VIZ,        2 * 1000).    %% Update VIZ every 2 seconds

start(State) ->

  %%
  %% This is to become the gen-server that will send snapshot information to the RealTime VIZ
  %%  

  %%                                {HostMatch, list({Path, Handler,                       Opts})}
  Dispatch = cowboy_router:compile([{'_',       [    {"/",  concurix_trace_socket_handler, [self()]} ] } ]),

  %%                Name, NbAcceptors, TransOpts,      ProtoOpts
  cowboy:start_http(http, 100,         [{port, 6788}], [{env, [{dispatch, Dispatch}]}]),

  {ok, _T1}  = timer:apply_interval(?TIMER_INTERVAL_VIZ, ?MODULE, send_summary,  [State]).

%%
%%
%% 

send_summary(State)->
%%  io:format("concurix_runtime:send_summary/1~n"),

  case gproc:lookup_pids({p, l, "benchrun_tracing"}) of
    [] ->
      ok;

    [Pid] ->
      Pid ! { trace, concurix_runtime:get_current_json(State) };

    _  ->
      ok
  end.

%%
%% gen_server support
%%

init([_Config]) ->
  {ok, undefined}.
 
handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
handle_info({websocket_init, WebSocketPid}, State) ->
  io:format("concurix_send_to_viz:handle_info/2 ~p~n", [WebSocketPid]),
  {noreply, State};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.
