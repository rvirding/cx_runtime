-record(tcstate, 
        { 
          runInfo, 

          processTable, 
          linkTable, 
          sysProfTable, 
          procLinkTable, 
          eventTimeTable,

          traceSupervisor,

          collectTraceData,
          sendUpdates,

          processCounter
        }).
