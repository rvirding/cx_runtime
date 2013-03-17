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
%% This gen_server handles tracing data coming in from systemtap
%%
-module(concurix_trace_by_systemtap).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("concurix_runtime.hrl").

start_link(State) ->
  gen_server:start_link(?MODULE, [State], []).

init([State]) ->
  io:format("got systemtap init ~p ~n", [State]),
  Port = open_port({spawn, "./loop.sh"}, [stream, {line, 2048}, eof]),
  io:format("Port = ~p ~n", [Port]),
  {ok, Port}.

handle_call(_Call, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
 

handle_info(Msg, State) ->
  io:format("got msg ~p ~n", [Msg]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.
