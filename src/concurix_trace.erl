-module(concurix_trace).

-export([top_pure_funs/0, top_pure_funs/1,
        pure_funs/0, pure_funs/1]).

%% Return a list of the top pure functions, in the form of MFA tuples,
%% for the currently loaded modules.  The top pure functions are ones
%% that are pure but called by some impure function.
-spec top_pure_funs() -> [{atom(), atom(), integer()}].
top_pure_funs() ->
    %% Can we avoid analyzing all loaded modules each time this
    %% function is called?
    %% Skip preloaded and cover_compiled modules.
    Modules = lists:filter(fun({_, Loaded}) ->
                                   is_list(Loaded)
                           end,
                           code:all_loaded()),
    PurityLookupTable = lookup_table(),
    purity:top_funs_from_modules(Modules, [{purelevel, 2}, {plt, PurityLookupTable}]).


%% Return a list of the top pure functions contained in a list of modules.
%% Ensures that modules are loaded as a side effect.
-spec top_pure_funs(list(module())) -> [{atom(), atom(), integer()}].
top_pure_funs(ModuleList) ->
    Modules = lists:foldl(fun(ModuleName, Acc) ->
                                  case ensure_loaded(ModuleName) of
                                      {file, Filename} ->
                                          [{ModuleName, Filename} | Acc];
                                      false ->
                                          Acc
                                  end
                          end, [], ModuleList),
    PurityLookupTable = lookup_table(),
    purity:top_funs_from_modules(Modules, [{purelevel, 2}, {plt, PurityLookupTable}]).


%% Return a list of all pure functions, in the form of MFA tuples,
%% for the currently loaded modules.  The top pure functions are ones
%% that are pure but called by some impure function.
-spec pure_funs() -> [{atom(), atom(), integer()}].
pure_funs() ->
    %% Can we avoid analyzing all loaded modules each time this
    %% function is called?
    %% Skip preloaded and cover_compiled modules.
    Modules = lists:filter(fun({_, Loaded}) ->
                                   is_list(Loaded)
                           end,
                           code:all_loaded()),
    PurityLookupTable = lookup_table(),
    purity:pure_funs_from_modules(Modules, [{purelevel, 2}, {plt, PurityLookupTable}]).


%% Return a list of all pure functions contained in a list of modules.
%% Ensures that modules are loaded as a side effect.
-spec pure_funs(list(module())) -> [{atom(), atom(), integer()}].
pure_funs(ModuleList) ->
    Modules = lists:foldl(fun(ModuleName, Acc) ->
                                  case ensure_loaded(ModuleName) of
                                      {file, Filename} ->
                                          [{ModuleName, Filename} | Acc];
                                      false ->
                                          Acc
                                  end
                          end, [], ModuleList),
    PurityLookupTable = lookup_table(),
    purity:pure_funs_from_modules(Modules, [{purelevel, 2}, {plt, PurityLookupTable}]).


%% Ensure that the given module is loaded and return its absolute pathname
%% if successful, or false if the module could not be loaded or does not
%% have a pathname.
-spec ensure_loaded(module()) -> {file, string()} | false.
ensure_loaded(ModuleName) ->
    case code:is_loaded(ModuleName) of
        false ->
            case code:which(ModuleName) of
                Filename when is_list(Filename) ->
                    case code:load_file(ModuleName) of
                        {module, ModuleName} ->
                            {file, Filename};
                        _ ->
                            % Failed to load
                            false
                    end;
                _ ->
                    % Not found in code path
                    false
            end;
        {file, Filename} when is_list(Filename) ->
            {file, Filename};
        {file, _} ->
            % Has no filename
            false
    end.

%% Find the purity lookup table based on a setting in the config file or
%% from the default location.
-spec lookup_table() -> string() | {error, enoent}.
lookup_table() ->
    case ets:lookup(concurix_config_master, purity_lookup_table) of
        [LookupTable] ->
            LookupTable;
        [] ->
            Filename = code:which(purity),
            LookupTable = filename:join(filename:dirname(filename:dirname(Filename)), "initial.plt"),
            case filelib:is_regular(LookupTable) of
                true ->
                    LookupTable;
                false ->
                    {error, enoent}
            end
    end.
