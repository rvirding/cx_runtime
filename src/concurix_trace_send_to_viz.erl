-module(concurix_trace_send_to_viz).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TIMER_INTERVAL_VIZ, 2 * 1000).    %% Update VIZ every 2 seconds

start_link(State) ->
  gen_server:start_link(?MODULE, [State], []).

init([State]) ->
%%  io:format("concurix_trace_send_to_viz:init/1                        ~p~n", [self()]),

  %%                                {HostMatch, list({Path, Handler,                       Opts})}
  Dispatch = cowboy_router:compile([{'_',       [    {"/",  concurix_trace_socket_handler, [self()]} ] } ]),

  %%                Name, NbAcceptors, TransOpts,      ProtoOpts
  cowboy:start_http(http, 10,          [{port, 6788}], [{env, [{dispatch, Dispatch}]}]),

  timer:send_after(?TIMER_INTERVAL_VIZ, send_to_viz),

  {ok, State}.
 
handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
handle_info({websocket_init, WebSocketPid}, State) ->
  io:format("concurix_send_to_viz:handle_info/2 websocket_init ~p~n", [WebSocketPid]),
  {noreply, State};

handle_info(send_to_viz, State) ->
  timer:send_after(?TIMER_INTERVAL_VIZ, send_to_viz),

  case gproc:lookup_pids({p, l, "benchrun_tracing"}) of
    [] ->
      ok;

    _  ->
      Json = concurix_runtime:get_current_json(State),
      gproc:send({p, l, "benchrun_tracing"}, {trace, Json})
  end,

  {noreply, State};

handle_info(Info, State) ->
  io:format("concurix_send_to_viz:handle_info/2 Unexpected message ~p~n", [Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.
