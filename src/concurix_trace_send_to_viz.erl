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
%% Send data to a browser via a websocket for real time visualizations.
%%
-module(concurix_trace_send_to_viz).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("concurix_runtime.hrl").

-spec start_link(_) -> 'ignore' | {'error',_} | {'ok',pid()}.
start_link(State) ->
  gen_server:start_link(?MODULE, [State], []).

init([State]) ->
  timer:send_after(State#tcstate.timer_interval_viz, send_to_viz),

  {ok, State}.

handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.


handle_info(send_to_viz, #tcstate{api_key = APIKey,
                                  send_updates = SendUpdates,
                                  run_info = RunInfo,
                                  disable_posts = DisablePosts} = State) ->

    if
	(SendUpdates == true) ->
	    timer:send_after(State#tcstate.timer_interval_viz, send_to_viz);
	true -> ok
    end,

    Url = binary_to_list(proplists:get_value(<<"trace_url">>, RunInfo)),
    Json = concurix_lib:get_current_json(State),

    case DisablePosts of
      false ->
        send_request(Url, Json, APIKey);
      _ ->
        ok
    end,
    %% After sending out the update to the server we have to reset the message
    %% counters in the trace_by_process gen_server.
    concurix_trace_by_process:reset_link_counters(),
    {noreply, State};

handle_info(stop_updating,                  State) ->
  {noreply, State#tcstate{send_updates = false}};

handle_info(Msg,                            State) ->
  io:format("~p:handle_info/2 Unexpected message ~p~n", [?MODULE, Msg]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_oldVsn, State, _Extra) ->
  {ok, State}.

viz_make_post_http_request(Url, Json, APIKey) ->
    BinLen = io_lib:write(iolist_size(Json)),

    Headers = [{"Concurix-API-Key", APIKey},
	       {"content-type","application/json"},
	       {"content-length",BinLen}],
    {Url,Headers,"application/json",Json}.

-spec send_request([byte()],binary(),'undefined' | string()) -> any().
send_request(Url, Json, APIKey) ->
  Request = viz_make_post_http_request(Url, Json, APIKey),
  httpc:request(post, Request, [{timeout, 60000}], [{sync, true}]).

