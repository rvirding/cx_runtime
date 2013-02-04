-module(concurix_trace_socket_handler).
-behaviour(cowboy_http_handler).
-behaviour(cowboy_http_websocket_handler).
-export([init/3, handle/2, terminate/2]).
-export([
    websocket_init/3, websocket_handle/3,
    websocket_info/3, websocket_terminate/3
]).

init({tcp, http}, Req, _Opts) ->
	%%io:format("Req = ~p ~n", [Req]),
	gproc:reg({p, l, "benchrun_tracing"} ),
	{upgrade, protocol, cowboy_websocket}.

handle(Req, State) ->
    {ok, Req2} = cowboy_http_req:reply(404, [{'Content-Type', <<"text/html">>}]),
    {ok, Req2, State}.

terminate(_Req, _State) ->
    ok.

websocket_init(_Any, Req, []) ->
    {ok, Req, undefined}.

websocket_handle({text, Msg}, Req, State) ->
    {reply,
        {text, << "responding to ", Msg/binary >>}, Req, State, hibernate
    };

websocket_handle(_Any, Req, State) ->
    {ok, Req, State}.

websocket_info({trace, Data}, Req, State) ->	
    {reply,{text, list_to_binary(Data)}, Req, State, hibernate};

websocket_info(_Info, Req, State) ->
	{ok, Req, State, hibernate}.

websocket_terminate(_Reason, _Req, _State) ->
    ok.