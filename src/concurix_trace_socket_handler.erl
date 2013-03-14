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
%% The websocket handler for Cowboy, used by send_to_viz.
%%
-module(concurix_trace_socket_handler).

-behaviour(cowboy_http_handler).
-export([init/3,           handle/2,                             terminate/2]).


-behaviour(cowboy_websocket_handler).
-export([websocket_init/3, websocket_handle/3, websocket_info/3, websocket_terminate/3]).

init({tcp, http}, _Req, _Opts) ->
  {upgrade, protocol, cowboy_http_websocket}.

handle(_Req, State) ->
  {ok, Req2} = cowboy_http_req:reply(404, [{'Content-Type', <<"text/html">>}]),
  {ok, Req2, State}.

terminate(_Req, _State) ->
  ok.

websocket_init(_Any, Req, _Opt) ->
  gproc:reg({p, l, "benchrun_tracing"}),
  Req2 = cowboy_http_req:compact(Req),
  {ok, Req2, undefined, hibernate}.

websocket_handle({text, Msg}, Req, State) ->
  {reply, {text, << "responding to ", Msg/binary >>}, Req, State, hibernate };

websocket_handle(_Any, Req, State) ->
  {ok, Req, State}.

websocket_info({trace, Data}, Req, State) ->
  {reply, {text, list_to_binary(Data)}, Req, State, hibernate};

websocket_info(_Info, Req, State) ->
  {ok, Req, State, hibernate}.

websocket_terminate(_Reason, _Req, _State) ->
  ok.
