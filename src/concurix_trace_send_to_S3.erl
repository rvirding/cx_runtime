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

  RunInfo = State#tcstate.runInfo,
  Url     = binary_to_list(proplists:get_value(<<"trace_url">>, RunInfo)),
  Fields  = snapshot_fields(RunInfo),
  Json    = concurix_runtime:get_current_json(State),
  Request = s3_make_post_http_request(Url, Fields, Json),
  httpc:request(post, Request, [{timeout, 60000}], [{sync, true}]),

  {noreply, State};

handle_info(stop_updating,                           State) ->
  {noreply, State#tcstate{sendUpdates = false}};

handle_info(Msg, State) ->
  io:format("~p:handle_info/2 Unexpected message ~p~n", [?MODULE, Msg]),
  {noreply, State}.

snapshot_fields(RunInfo) ->
  Run_id              = binary_to_list(proplists:get_value(<<"run_id">>, RunInfo)),
  Fields              = proplists:get_value(<<"fields">>, RunInfo),

  {Mega, Secs, Micro} = now(),

  KeyString           = io_lib:format("json_realtime_trace_snapshot.~p.~p-~6..0w-~6..0w", [node(), Mega, Secs, Micro]),
  Key                 = lists:flatten(KeyString),

  case proplists:is_defined(<<"key">>, Fields) of
    true  ->
      Temp = proplists:delete(<<"key">>, Fields);

    false -> 
      Temp = Fields
  end,

  Temp ++ [{<<"key">>, list_to_binary(Run_id ++ "/" ++ Key)}].
 
terminate(_Reason, _State) ->
  ok.
 
code_change(_oldVsn, State, _Extra) ->
  {ok, State}.












%%
%% This function is taken from erlcloud_s3.erl
%%

s3_make_post_http_request(Url, Fields, Data) ->
  Boundary = "-------erlcloud_s3---AG121712-----",
  Body     = format_multipart_formdata(Boundary, Fields, Data),

  {Url, [{"Content-Length"}, integer_to_list(length(Body))], "multipart/form-data; boundary=" ++ Boundary, Body}.

%%
%% credit to http://lethain.com/formatting-multipart-formdata-in-erlang/ for the original code here
%%
format_multipart_formdata(Boundary, Fields, Data) when is_binary(Data) ->
  format_multipart_formdata(Boundary, Fields, binary_to_list(Data), "application/octet-stream");

format_multipart_formdata(Boundary, Fields, Data) when is_list(Data) ->
  format_multipart_formdata(Boundary, Fields, Data, "text/plain").

format_multipart_formdata(Boundary, Fields, Data, Type) ->
  FieldParts  = lists:map(fun({FieldName, FieldContent}) ->
                            [lists:concat(["--", Boundary]),
                             lists:concat(["Content-Disposition: form-data; name=\"",
                                           binary_to_list(FieldName),
                                           "\""]),
                             "",
                             convert_to_list(FieldContent)]
                            end, 
                          Fields),
  FieldParts2 = lists:append(FieldParts),

  FileParts   = [[lists:concat(["--", Boundary]),
                  lists:concat(["Content-Disposition: form-data; name=\"file\""]),
                  lists:concat(["Content-Type: ", Type]),
                  "",
                  Data]],
  FileParts2  = lists:append(FileParts),

  EndingParts = [lists:concat(["--", Boundary, "--"]), ""],

  Parts       = lists:append([FieldParts2, FileParts2, EndingParts]),

  string:join(Parts, "\r\n").

convert_to_list(Data) when is_list(Data)->
  Data;
convert_to_list(Data) when is_binary(Data)->
  binary_to_list(Data);
convert_to_list(Data) when is_integer(Data)->
  integer_to_list(Data).
  

