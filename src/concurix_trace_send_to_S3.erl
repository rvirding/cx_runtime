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
%% Sends tracing data to Concurix's S3 instances in JSON format.
%%
-module(concurix_trace_send_to_S3).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("concurix_runtime.hrl").

-define(TIMER_INTERVAL_S3, 2 * 1000).    %% Update S3  every 2 seconds

start_link(State) ->
  gen_server:start_link(?MODULE, [State], []).

%%
%% gen_server support
%%

init([State]) ->
  timer:send_after(?TIMER_INTERVAL_S3, send_snapshot),

  {ok, State}.

handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 
handle_info(send_snapshot, State) ->
  if 
    (State#tcstate.sendUpdates == true) ->
      timer:send_after(?TIMER_INTERVAL_S3, send_snapshot);

    true ->
      ok
  end,

  RunInfo             = State#tcstate.runInfo,
  Url                 = proplists:get_value(trace_url, RunInfo),
  Fields              = snapshot_fields(RunInfo),
  Json                = concurix_runtime:get_current_json(State),
  Data                = list_to_binary(Json),

  Request             = erlcloud_s3:make_post_http_request(Url, Fields, Data),

  httpc:request(post, Request, [{timeout, 60000}], [{sync, true}]),

  {noreply, State};

handle_info(stop_updating,                           State) ->
  {noreply, State#tcstate{sendUpdates = false}};

handle_info(Msg, State) ->
  io:format("~p:handle_info/2 Unexpected message ~p~n", [?MODULE, Msg]),
  {noreply, State}.

snapshot_fields(RunInfo) ->
  Run_id              = proplists:get_value(run_id, RunInfo),
  Fields              = proplists:get_value(fields, RunInfo),

  {Mega, Secs, Micro} = now(),

  KeyString           = io_lib:format("json_realtime_trace_snapshot.~p.~p-~6..0w-~6..0w", [node(), Mega, Secs, Micro]),
  Key                 = lists:flatten(KeyString),

  case proplists:is_defined(key, Fields) of
    true  ->
      Temp = proplists:delete(key, Fields);

    false -> 
      Temp = Fields
  end,

  Temp ++ [{key, Run_id ++ "/" ++ Key}].
 
terminate(_Reason, _State) ->
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.

