-define(DEFAULT_TIMER_INTERVAL_VIZ, 2 * 1000).   %% Update VIZ every 2 seconds

-record(tcstate,
        {
          runInfo,

          processTable,
          linkTable,
          sysProfTable,
          procLinkTable,

          lastNodes,

          traceSupervisor,

          collectTraceData,
          sendUpdates,
          traceMf,
          apiKey,
          displayPid,
          timerIntervalViz
        }).

