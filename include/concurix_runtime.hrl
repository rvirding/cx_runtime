-record(tcstate, 
        { 
          runInfo, 

          processTable, 
          linkTable, 
          sysProfTable, 
          procLinkTable, 
          eventTimeTable,
          eventWholeDict,

          processDict,
          eventTimeDict,

          traceSupervisor,

          collectTraceData,
          sendUpdates,

          processCounter,
          maxQueueLen
        }).
