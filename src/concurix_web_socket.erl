-module(concurix_web_socket).
-export([start/0]).

start() ->
  {ok, L} = gen_tcp:listen(6788, [binary, {active, once}, {reuseaddr, true}, {packet, 0}]),
  spawn(fun() -> acceptor(L) end).

% Accepts multiple connections and handles them separately.
acceptor(L)->
  %% This Erlang process will block until there is a connection request, presumably from the VIZ browser
  {ok, S} = gen_tcp:accept(L),

  %% Spawn a new Erlang process to listen for another connection request
  spawn(fun()->acceptor(L) end),

  %% Verify that the requester is establishing a web socket
  validate_websocket(S).

validate_websocket(S) ->
  receive
    {tcp, S, Bin} -> 
      Challenge = process_handshake_key(Bin),

      % Send the Handshake stuff to the browser.
      gen_tcp:send(S, "HTTP/1.1 101 Switching Protocols\r\n"),
      gen_tcp:send(S, "Upgrade: websocket\r\n"),
      gen_tcp:send(S, "Connection: Upgrade\r\n"),
      gen_tcp:send(S, "Sec-WebSocket-Accept: " ++ Challenge ++ "\r\n"),
      gen_tcp:send(S, "\r\n"),

      % Indicate willingness to receive one more message
      inet:setopts(S, [{active, once}]),

      %% Add this process to the list that will receive trace messages
      gproc:reg({p, l, "benchrun_tracing"}),

      %% Handle trace messages
     loop(S)
  end.

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

process_handshake_key(X) ->
  Tokens    = string:tokens(binary_to_list(X), "\r\n"),
  Req       = [ token_to_kv(A) || A <- Tokens],
  Key       = proplists:get_value("Sec-WebSocket-Key", Req),
  GUID      = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",                  %% Protocol key per RFC4122
  Challenge = base64:encode(crypto:sha(list_to_binary(Key ++ GUID))),

  binary_to_list(Challenge).

token_to_kv(Token) ->
  case string:tokens(Token, ":") of
    [A, B] ->
      {A, string:strip(B)};

    [X] ->
      {other, X};

    Y ->
      {yikes, Y}
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
