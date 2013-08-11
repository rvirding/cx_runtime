-module(concurix_web_socket).
-export([start/0]).

start() ->
  {ok, L} = gen_tcp:listen(6788, [binary, {active, false}, {reuseaddr, true}, {packet, 0}]),
  spawn(fun() -> acceptor(L) end).

% Accepts multiple connections and handles them separately.
acceptor(L)->
  %% This Erlang process will block until there is a connection request
  case gen_tcp:accept(L) of
    {ok, S} ->
      %% Spawn a new Erlang process to listen for another connection request
      spawn(fun() -> acceptor(L) end),

      %% Verify that the requester is establishing a web socket
      validate_websocket(S);

    % The last acceptor may see L get closed
    _ ->
      ok
  end.

%%
%% A new connection has been established.
%% Determine if it is minimally consistent with a Concurix VIZ web-socket request
%%
validate_websocket(S) ->
  % Indicate willingness to accept one TCP message
  inet:setopts(S, [{active, once}]),

  receive
    {tcp, S, Bin} -> 
      case erlang:decode_packet(http, Bin, []) of
        { ok, {http_request, 'GET', {abs_path, _}, {1, 1}}, Rest } ->
          validate_websocket_headers(S, Rest, 0, 0, undefined);

        _ ->
          validate_websocket(S)
      end;

    {tcp_closed, S} ->
      ok
  end.

validate_websocket_headers(S, Bin, UpgradeCount, ConnectionCount, Key) ->
  case erlang:decode_packet(httph, Bin, []) of
    {ok, {http_header, _, 'Upgrade', _, "websocket"}, Rest} ->
      validate_websocket_headers(S, Rest, UpgradeCount + 1, ConnectionCount,     Key);

    {ok, {http_header, _, 'Connection', _, "Upgrade"}, Rest} ->
      validate_websocket_headers(S, Rest, UpgradeCount,     ConnectionCount + 1, Key);

    {ok, {http_header, _, "Sec-Websocket-Key", _, Value}, Rest} ->
      validate_websocket_headers(S, Rest, UpgradeCount,     ConnectionCount,     Value);

    {ok, {http_header, _, _Field, _, _Value}, Rest} ->
      validate_websocket_headers(S, Rest, UpgradeCount,     ConnectionCount,     Key);

    {ok, http_eoh, _} ->
      validate_websocket_headers_eval(S, Bin, UpgradeCount, ConnectionCount,     Key);

    _ ->
      % Indicate willingness to receive one more message
      inet:setopts(S, [{active, once}]),
      validate_websocket(S)
  end.



%%
%% All of the headers have been scanned.  Is this a plausible web-socket request?
%%

validate_websocket_headers_eval(S, _Bin, 1, 1, Key) when is_list(Key) ->
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


%%
%%
%%

loop(S)->
  receive
    {tcp_closed, S} ->
      ok;

    {trace, Json} -> 
      Opcode = websocket_opcode(text),
      BinLen = payload_length_to_binary(iolist_size(Json)),

      gen_tcp:send(S, [<< 1:1, 0:3, Opcode:4, 0:1, BinLen/bits >>, Json]),

      loop(S);

    _ ->
      loop(S)
  end.

websocket_opcode(text)   ->  1;
websocket_opcode(binary) ->  2;
websocket_opcode(close)  ->  8;
websocket_opcode(ping)   ->  9;
websocket_opcode(pong)   -> 10.

payload_length_to_binary(N) ->
  case N of
      N when N =< 125                 -> << N:7 >>;
      N when N =< 16#ffff             -> << 126:7, N:16 >>;
      N when N =< 16#7fffffffffffffff -> << 127:7, N:64 >>
  end.
