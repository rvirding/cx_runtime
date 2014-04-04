-define(DEFAULT_TIMER_INTERVAL_VIZ, 2 * 1000).   %% Update VIZ every 2 seconds

-record(tcstate,
        {
          run_info                  :: proplist:proplist(),

          process_table             :: ets:tid(),
          link_table                :: ets:tid(),
          sys_prof_table            :: ets:tid(),
          proc_link_table           :: ets:tid(),
          reduction_table           :: ets:tid(),

          last_nodes                :: ets:tid(),

          trace_supervisor          :: boolean(),

          collect_trace_data        :: boolean(),
          send_updates              :: boolean(),       
          trace_mf                  :: {Mod :: atom(), Function :: atom()},
          api_key                   :: string(),
          display_pid               :: boolean(),
          timer_interval_viz        :: integer(),
          disable_posts             :: boolean()
        }).

