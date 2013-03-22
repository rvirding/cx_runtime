-module(concurix_web_socket).
-export([start/0]).

start() ->
  {ok, L} = gen_tcp:listen(6788, [binary, {active, false}, {reuseaddr, true}, {packet, 0}]),
  spawn(fun() -> acceptor(L) end).

% Accepts multiple connections and handles them separately.
acceptor(L)->
  %% This Erlang process will block until there is a connection request
  {ok, S} = gen_tcp:accept(L),

  %% Spawn a new Erlang process to listen for another connection request
  spawn(fun()->acceptor(L) end),

  %% Verify that the requester is establishing a web socket
  validate_websocket(S).

%% A new connection has been established.
%% Determine if it is, at least, consistent with a Concurix VIZ web-socket request
validate_websocket(S) ->
  % Indicate willingness to accept one TCP message
  inet:setopts(S, [{active, once}]),

  receive
    {tcp, S, Bin} -> 
      io:format("~p:validate_websocket/1~n  ~p~n", [?MODULE, binary_to_list(Bin)]),

      case erlang:decode_packet(http, Bin, []) of
        { ok, {http_request, 'GET', {abs_path, "/"}, {1, 1}}, Rest } ->
          validate_websocket_headers(S, Rest, false, false, undefined);

        _ ->
          validate_websocket(S)
      end;

    {tcp_closed, S} ->
      io:format("Socket ~p closed without a web-socket upgrade~n", [S]),
      ok
  end.

validate_websocket_headers(S, Bin, Update, Connection, Key) ->
  case erlang:decode_packet(httph, Bin, []) of
    {ok, {http_header, _, 'Upgrade', _, "websocket"}, Rest} ->
      io:format("Upgrade:    websocket~n"),
      validate_websocket_headers(S, Rest, true, Connection, Key);

    {ok, {http_header, _, 'Connection', _, "Upgrade"}, Rest} ->
      io:format("Connection: Upgrade~n"),
      validate_websocket_headers(S, Rest, Update, true, Key);

    {ok, {http_header, _, "Sec-Websocket-Key", _, Value}, Rest} ->
      io:format("Sec-Websocket-Key: ~p~n", [Value]),
      validate_websocket_headers(S, Rest, Update, Connection, Value);

    {ok, {http_header, _, _Field, _, _Value}, Rest} ->
      validate_websocket_headers(S, Rest, Update, Connection, Key);

    {ok, http_eoh, _} ->
      validate_websocket_headers_eval(S, Bin, Update, Connection, Key)
  end.

validate_websocket_headers_eval(S, _Bin, true, true, Key) when is_list(Key) ->
  GUID      = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",                %% Per RFC4122
  Challenge = base64:encode(crypto:sha(list_to_binary(Key ++ GUID))),

  % Send the Handshake stuff to the browser.
  gen_tcp:send(S, "HTTP/1.1 101 Switching Protocols\r\n"),
  gen_tcp:send(S, "Upgrade: websocket\r\n"),
  gen_tcp:send(S, "Connection: Upgrade\r\n"),
  gen_tcp:send(S, "Sec-WebSocket-Accept: " ++ binary_to_list(Challenge) ++ "\r\n"),
  gen_tcp:send(S, "\r\n"),

  % Add this process to the list that will receive trace messages
  gproc:reg({p, l, "benchrun_tracing"}),

  % Indicate willingness to receive one more message
  inet:setopts(S, [{active, once}]),

  % Handle trace messages
  loop(S);

validate_websocket_headers_eval(S, _Bin, _Update, _Connection, _Key) ->
  % Indicate willingness to receive one more message
  inet:setopts(S, [{active, once}]),

  % Retry waiting for websocket request
  validate_websocket(S).

loop(S)->
  receive
    {tcp_closed, S} ->
      io:format("Socket ~p closed~n", [S]),
      ok;

    {trace, Json} -> 
      websocket_send_text(S, Json),
      loop(S);

    _Any ->
      loop(S)
  end.

websocket_send_text(Socket, Payload) ->
  Opcode = websocket_opcode(text),
  Len    = iolist_size(Payload),
  BinLen = payload_length_to_binary(Len),

  gen_tcp:send(Socket, [<< 1:1, 0:3, Opcode:4, 0:1, BinLen/bits >>, Payload]).
        
websocket_opcode(text)   ->  1;
websocket_opcode(binary) ->  2;
websocket_opcode(close)  ->  8;
websocket_opcode(ping)   ->  9;
websocket_opcode(pong)   -> 10.

payload_length_to_binary(N) ->
  case N of
      N when N =< 125 -> << N:7 >>;
      N when N =< 16#ffff -> << 126:7, N:16 >>;
      N when N =< 16#7fffffffffffffff -> << 127:7, N:64 >>
  end.
