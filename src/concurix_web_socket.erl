-module(concurix_web_socket).
-compile(export_all).
-author({jha, abhinav}).


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
    Child = spawn(fun() -> handshake_and_talk(Pid) end),
    gproc:reg({p, l, "benchrun_tracing"}),
    loop(S, Child).

loop(S, Child)->
    receive
        {tcp, S, Bin} -> 
            Child ! {self(), Bin}, 
            loop(S, Child);
        {Child, X} ->
            io:format("sending ~p to ~p ~n", [X, S]),
            gen_tcp:send(S, X),
            loop(S, Child);
        {trace, Json} -> 
            io:format("sending json ~p ~n", [lists:flatten(Json)]),
            websocket_send_text(S, Json),
            loop(S, Child);
        _Any ->
            loop(S, Child)
    end.
            

% Handshake with the client and begin talking.
handshake_and_talk(Ppid)->
    receive
        {Ppid, X} ->
            io:format("got connection request of ~p ~n", [X]),
            % Body = the checksum comprised after processing Key1, Key2 and the Client's request body.
            %Body = process_client_handshake(binary_to_list(X)),
            Challenge = process_handshake_key(X),
            % Send the Handshake stuff to the browser.
            Ppid ! {self(), "HTTP/1.1 101 Switching Protocols\r\n"},
            Ppid ! {self(), "Upgrade: websocket\r\n"},
            Ppid ! {self(), "Connection: Upgrade\r\n"},
            %%Ppid ! {self(), "Sec-WebSocket-Origin: http://127.0.0.1:8080\r\n"},
            %%Ppid ! {self(), "Sec-WebSocket-Location: ws://127.0.0.1:8000/\r\n"},
            %%Ppid ! {self(), "Sec-WebSocket-Protocol: chat\r\n"},
            Ppid ! {self(), "Sec-WebSocket-Accept: " ++ Challenge ++ "\r\n" },
            Ppid ! {self(), "\r\n"};

            % Send the body. 
            %Ppid ! {self(), Body};

            % Now call the talk method to do the actual talking with the browser.
            % talk(Ppid);

        Any -> io:format("[Child] Random stuff received:~p~n. ~p", [Any, Ppid]) 
    end.


% Function to actuall talk to the browser.
% Dummy implementation -  Implement as reuired.
talk(Browser) ->
    receive
    after 1000 ->
            % This is the main communicator function to the Browser.
            % Whatever you write instead of "Hahah" will get sent to the browser.
            % the 0 and 255 is the framing ( required) - don't change that. 
            Browser ! {self(), [0]},
            Browser ! {self(), "Hahah"},
            Browser ! {self(), [255]},
            talk(Browser)
    end.

process_handshake_key(X) ->
  Tokens = string:tokens(binary_to_list(X), "\r\n"),
  Req = [ token_to_kv(A) || A <- Tokens],
  Key = proplists:get_value("Sec-WebSocket-Key", Req),
  Challenge = base64:encode(crypto:sha(list_to_binary(Key ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))),
  io:format("key ~p challenge ~p ~n", [Key, Challenge]),
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
  
% Process client's handshake to retrieve information.
process_client_handshake(X)->
    [Body|Head] = lists:reverse(string:tokens(X, "\r\n")),
    {Key1, Key2} = extract_keys(lists:reverse(Head)),
    {Skey1, Skey2} = process_keys(Key1, Key2),
    Bin_body = list_to_binary(Body),
    Key = <<Skey1:32/big-unsigned-integer, Skey2:32/big-unsigned-integer, Bin_body/binary>>,
    erlang:md5(Key).

% Extract keys from the client's handshake.
extract_keys([H|T])->
    Key1 = extract_key("Sec-WebSocket-Key: ", [H|T]),
    Key2 = extract_key("Sec-WebSocket-Key2: ", [H|T]),
    {Key1, Key2}.

extract_key(X, [H|T])->
    case string:str(H, X) of
        0 -> extract_key(X, T); 
        _Pos -> string:substr(H, string:len(X) + 1)
    end.

% Process the keys as mentioned in the handshake 76 draft of the ietf.
process_keys(Key1, Key2)->
    {Digits1, []} = string:to_integer(digits(Key1)),
    {Digits2, []} = string:to_integer(digits(Key2)),
    Spaces1 = spaces(Key1),
    Spaces2 = spaces(Key2),
    {Digits1 div Spaces1, Digits2 div Spaces2}.

% Concatenate digits 0-9 of a string 
digits(X)-> [A || A<-X, A =< 57, A >= 48].

% Count number of spaces in a string.
spaces(X)-> string:len([ A || A<-X, A =:= 32]).

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