-define(DEFAULT_TIMER_INTERVAL_VIZ, 2 * 1000).   %% Update VIZ every 2 seconds

-record(tcstate,
        {
          run_info,

          process_table,
          link_table,
          sys_prof_table,
          proc_link_table,

          last_nodes,

          trace_supervisor,

          collect_trace_data,
          send_updates,
          trace_mf,
          api_key,
          display_pid,
          timer_interval_viz
        }).

