-module(concurix_file).

-export([transmit_to_s3/3]).

transmit_to_s3(Run_id, Url, Fields) ->
	inets:start(),
	ssl:start(),
	%%temp for now
	io:format("url, fields: ~p ~p ~n", [Url, Fields]),
	Request = erlcloud_s3:make_post_http_request(Url, Fields, "cx_runtimefoobarfoobar"),
	io:format("request: ~p ~n", [Request]),
	
	Res = httpc:request(
		post,
		Request,
		[{timeout, 60000}],
		[{sync, true}]			
	),
	io:format("post results ~p ~n", [Res]),
	ok.