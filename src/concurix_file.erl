-module(concurix_file).

-export([transmit_to_s3/3]).

transmit_to_s3(Run_id, Url, Fields) ->
	inets:start(),
	ssl:start(),
	
	case file:list_dir("/tmp/cx_data/" ++ Run_id) of
		{ok, Files} ->
			send_files(Files, Run_id, Url, Fields);
		_X ->
			io:format("error--no run directory found")
	end.
	
send_files([], _Run_id, _Url, _Fields) ->
	ok;
send_files([File | Tail], Run_id, Url, Fields) ->
	send_file(File, Run_id, Url, Fields),
	send_files(Tail, Run_id, Url, Fields).

send_file(File, Run_id, Url, Fields) ->
	SendFields = update_fields(Run_id, Fields, File),
	{ok, Data} = file:read_file("/tmp/cx_data/" ++ Run_id ++ "/" ++ File),
	
	io:format("url, fields: ~p ~p ~n", [Url, Fields]),
	io:format("data: ~p ~n", [Data]),
	Request = erlcloud_s3:make_post_http_request(Url, SendFields, Data),
	io:format("request: ~p ~n", [Request]),
	
	Res = httpc:request(
		post,
		Request,
		[{timeout, 60000}],
		[{sync, true}]			
	),
	io:format("post results ~p ~n", [Res]),
	ok.
	
update_fields(Run_id, Fields, File) ->
	Temp = proplists:delete(key, Fields),
	Temp ++ [{key, Run_id ++ "/" ++ File}].