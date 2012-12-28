-module(concurix_file).

-export([transmit_to_s3/5, transmit_dir_to_s3/4, permissioned_transmit_dir_to_s3/3]).
-export([recursively_list_dir/1,
         recursively_list_dir/2]).

% @type name() = string() | atom() | binary().
-type name() :: string() | atom() | binary().

%%
%% transmit directory to s3 **assuming** that erlcloud_s3:configure has been called with 
%% appropriate permissions by the calling process
permissioned_transmit_dir_to_s3(Bucket, Run_id, Dir) ->
	Files = cx_list_dir(Dir, true),
	permissioned_send_files(Files, Bucket, Run_id, Dir).

transmit_dir_to_s3(Run_id, Dir, Url, Fields) ->
	transmit_to_s3(Run_id, Dir, true, Url, Fields).

transmit_to_s3(Run_id, SubDir, Recurse, Url, Fields) ->
	inets:start(),
	ssl:start(),
	
	Dir = "/tmp/cx_data/" ++ Run_id ++ "/"++ SubDir,	
	Files = cx_list_dir(Dir, Recurse),
	
	Len = string:len(Dir) + 1,
	Subfiles = [ string:substr(X, Len) || X <- Files, string:len(X) > Len ],
	
	send_files(Subfiles, Run_id, Url, Fields).

permissioned_send_files([], _Bucket, _Run_id, _RootDir) ->
	ok;
permissioned_send_files([File | Tail], Bucket, Run_id, RootDir) ->
	permissioned_send_file(File, Bucket, Run_id, RootDir),
	permissioned_send_files(Tail, Bucket, Run_id, RootDir).
	
permissioned_send_file(File, Bucket, Run_id, RootDir) ->
	{ok, Data} = file:read_file(File),
	Key = Run_id ++ (File -- RootDir),
	Type = data_type(File),
	erlcloud_s3:put_object(Bucket, Key, Data, [{"content-type", Type}]).
	
send_files([], _Run_id, _Url, _Fields) ->
	ok;
send_files([File | Tail], Run_id, Url, Fields) ->
	send_file(File, Run_id, Url, Fields),
	send_files(Tail, Run_id, Url, Fields).

send_file(File, Run_id, Url, Fields) ->
	SendFields = update_fields(Run_id, Fields, File),
	{ok, Data} = file:read_file("/tmp/cx_data/" ++ Run_id ++ "/" ++ File),
	
	io:format("sending data for file ~p ", [File]),
	Request = erlcloud_s3:make_post_http_request(Url, SendFields, Data),
	io:format("request: ~p ~n", [Request]),
	
	Res = httpc:request(
		post,
		Request,
		[{timeout, 6000000}],
		[{sync, true}]			
	),
	io:format("post results ~p ~n", [Res]),
	ok.
	
update_fields(Run_id, Fields, File) ->
	Temp = proplists:delete(key, Fields),
	Temp ++ [{key, Run_id ++ "/" ++ File}].

%%
%% list the directory.  the second argument is fRecurse (to recurse or not)
cx_list_dir(Dir, true) ->
	{ok, Files} = recursively_list_dir(Dir, true),
	Files;
cx_list_dir(Dir, false) ->
	{ok, All } = file:list_dir(Dir),
	[ X || X <- All, filelib:is_regular(X)].

%%
%% Recursive file list from https://gist.github.com/1059710
%% Mrinal Wadhwa
%%
	
% @spec (Dir::name()) -> {ok, [string()]} | {error, atom()}
% @equiv recursively_list_dir(Dir, false)
% 
% @doc Lists all the files in a directory and recursively in all its
% sub directories. Returns {ok, Paths} if successful. Otherwise,
% it returns {error, Reason}. Paths is a list of Paths of all the
% files and directories in the input directory's subtree. The paths are not
% sorted in any order.

-spec recursively_list_dir(Dir::name()) ->
        {ok, [string()]} | {error, atom()}.

recursively_list_dir(Dir) ->
    recursively_list_dir(Dir, false). % default value of FilesOnly is false




% @spec (Dir::name(), FilesOnly::boolean()) -> {ok, [string()]} |
%                                                   {error, atom()}
% 
% @doc Lists all the files in a directory and recursively in all its
% sub directories. Returns {ok, Paths} if successful. Otherwise,
% it returns {error, Reason}. If FilesOnly is false, Paths is a list of paths
% of all the files <b>and directories</b> in the input directory's subtree.
% If FilesOnly is true, Paths is a list of paths of only the files in the
% input directory's subtree. The paths are not sorted in any order.

-spec recursively_list_dir(Dir::name(), FilesOnly::boolean()) ->
        {ok, [string()]} | {error, atom()}.

recursively_list_dir(Dir, FilesOnly) ->
    case filelib:is_file(Dir) of
        true ->
            case filelib:is_dir(Dir) of
                true -> {ok, recursively_list_dir([Dir], FilesOnly, [])};
                false -> {error, enotdir}
            end;
        false -> {error, enoent}
    end.




%% Internal

recursively_list_dir([], _FilesOnly, Acc) -> Acc;
recursively_list_dir([Path|Paths], FilesOnly, Acc) ->
    recursively_list_dir(Paths, FilesOnly,
        case filelib:is_dir(Path) of
            false -> [Path | Acc];
            true ->
                {ok, Listing} = file:list_dir(Path),
                SubPaths = [filename:join(Path, Name) || Name <- Listing],
                recursively_list_dir(SubPaths, FilesOnly,
                    case FilesOnly of
                        true -> Acc;
                        false -> [Path | Acc]
                    end)
        end).




%% Tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

non_existing_file_returns_error_test() ->
    ?assertEqual({error, enoent},
                 recursively_list_dir("UnUSuAalfIlEnaMe")),
    ok.

non_directory_input_returns_error_test() ->
    cleanup(),
    file:write_file("f1.test", <<"temp test file">>),
    ?assertEqual({error, enotdir}, 
                 recursively_list_dir("f1.test")),
    cleanup(),
    ok.

simple_test() ->
    cleanup(),
    filelib:ensure_dir("a/b/c/"),
    ?assertEqual({ok, ["a/b/c", "a/b", "a"]}, 
                 recursively_list_dir("a")),
    file:write_file("a/b/f.test", <<"temp test file">>),
    ?assertEqual({ok, ["a/b/c","a/b/f.test","a/b","a"]}, 
                 recursively_list_dir("a")),
    cleanup(),
    ok.

filesonly_test() ->
    cleanup(),
    filelib:ensure_dir("a/b/f.test"),
    file:write_file("a/b/f.test", <<"hello">>),
    ?assertEqual({ok, ["a/b/f.test"]}, 
                 recursively_list_dir("a", true)),
    cleanup(),
    ok.

cleanup() ->
    file:delete("f1.test"),
    file:delete("a/b/f.test"),
    file:del_dir("a/b/c"),
    file:del_dir("a/b"),
    file:del_dir("a"),
    ok.

-endif.	

data_type(File) ->
	case filename:extension(File) of
		".html" ->
			"text/html";
		".jpg" ->
			"image/jpeg";
		".jpeg" ->
			"image/jpeg";
		".png" ->
			"image/png";
		".log" ->
			"text/plain";
		".txt" ->
			"text/plain";
		".xml" ->
			"text/xml";
		".bin" ->
			"application/octet_stream";
		".zip" ->
			"application/zip";
		".css" ->
			"text/css";
		".json" ->
			"application/json";
		".javascript" ->
			"application/javascript";
		".pdf" ->
			"application/pdf";
		".erl" ->
			"text/plain";
		".gplit" ->
			"text/plain"
	end.			