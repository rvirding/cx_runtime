-module(concurix_web_socket).
-compile(export_all).


start() ->
    io:format("trying to start ~n"),
    {ok, L} = gen_tcp:listen(6788, [binary, {active, true}, {reuseaddr, true}, {packet, 0}]),
    io:format("got the listen to ~p ~n", [L]),
    %%erlang:process_flag(trap_exit, true),
    Pid = spawn_link(concurix_web_socket, acceptor, [L]).
    %%receive
    %%    {'EXIT', Pid, Why} -> 
    %%        io:format("Process ~p exited with ~p. ~n", [Pid, Why]);
    %%    Any -> 
    %%        io:format("~p~n", [Any])
    %% end.

% Accepts multiple connections and handles them separately.
acceptor(L)->
    {ok, S} = gen_tcp:accept(L),
    spawn(fun()->acceptor(L) end),
    handle(S).

% Not really required, just a wrapper over handle/2 in case we want to do something later.
handle(S)->
    handle(S, []).

handle(S, _Data)->
    Pid = self(),
    gproc:reg({p, l, "benchrun_tracing"}),
    loop(S).

loop(S)->
    receive
        {tcp, S, Bin} -> 
            Challenge = process_handshake_key(Bin),
            % Send the Handshake stuff to the browser.
            gen_tcp:send(S, "HTTP/1.1 101 Switching Protocols\r\n"),
            gen_tcp:send(S, "Upgrade: websocket\r\n"),
            gen_tcp:send(S, "Connection: Upgrade\r\n"),
            %%Ppid ! {self(), "Sec-WebSocket-Origin: http://127.0.0.1:8080\r\n"},
            %%Ppid ! {self(), "Sec-WebSocket-Location: ws://127.0.0.1:8000/\r\n"},
            gen_tcp:send(S, "Sec-WebSocket-Accept: " ++ Challenge ++ "\r\n"),
            gen_tcp:send(S, "\r\n"),
            loop(S);
        {trace, Json} -> 
            websocket_send_text(S, Json),
            loop(S);
        _Any ->
            loop(S)
    end.

process_handshake_key(X) ->
  Tokens = string:tokens(binary_to_list(X), "\r\n"),
  Req = [ token_to_kv(A) || A <- Tokens],
  Key = proplists:get_value("Sec-WebSocket-Key", Req),
  Challenge = base64:encode(crypto:sha(list_to_binary(Key ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))),
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

websocket_opcode(text) -> 1;
websocket_opcode(binary) -> 2;
websocket_opcode(close) -> 8;
websocket_opcode(ping) -> 9;
websocket_opcode(pong) -> 10.

websocket_send_text(Socket, Payload) ->
	Opcode = websocket_opcode(text),
	Len = iolist_size(Payload),
	BinLen = payload_length_to_binary(Len),
	gen_tcp:send(Socket,
		[<< 1:1, 0:3, Opcode:4, 0:1, BinLen/bits >>, Payload]).
		
payload_length_to_binary(N) ->
	case N of
		N when N =< 125 -> << N:7 >>;
		N when N =< 16#ffff -> << 126:7, N:16 >>;
		N when N =< 16#7fffffffffffffff -> << 127:7, N:64 >>
	end.		