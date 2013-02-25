-module(concurix_send_to_S3).

-behaviour(gen_server).

-export([start/2]).
-export([send_snapshot/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(tcstate, { runInfo, processTable, linkTable, sysProfTable }).

-define(TIMER_INTERVAL_S3,    2 * 60 * 1000).    %% Update S3  every 2 minutes

start(RunInfo, State) ->
  %%
  %% This is to become the gen-server that will send data to S3
  %%

  {ok, _T2}  = timer:apply_interval(?TIMER_INTERVAL_S3,  ?MODULE, send_snapshot, [RunInfo, State]).

send_snapshot(RunInfo, State) ->
  Url                 = proplists:get_value(trace_url, RunInfo),
  Fields              = snapshot_fields(RunInfo, State),
  Json                = concurix_runtime:get_current_json(State),
  Data                = list_to_binary(Json),

  Request             = erlcloud_s3:make_post_http_request(Url, Fields, Data),

  httpc:request(post, Request, [{timeout, 60000}], [{sync, true}]).

snapshot_fields(RunInfo, State) ->
  Run_id              = proplists:get_value(run_id, RunInfo),
  Fields              = proplists:get_value(fields, RunInfo),

  {Mega, Secs, Micro} = now(),
  KeyString           = io_lib:format("json_realtime_trace_snapshot.~p.~p-~p-~p",[node(), Mega, Secs, Micro]),
  Key                 = lists:flatten(KeyString),

  case proplists:is_defined(key, Fields) of
    true  ->
      Temp = proplists:delete(key, Fields);

    false -> 
      Temp = Fields
  end,

  Temp ++ [{key, Run_id ++ "/" ++ Key}].

%%
%% gen_server support
%%

init([_Config]) ->
  {ok, undefined}.
 
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
