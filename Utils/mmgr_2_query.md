# QueryContext

## 执行阶段

```
TopPortalContext
└── PortalContext
	└── QueryContext("ExecutorState")
		├── ExprContext
		└── tmpcontext("printtup")
```

## "simple Query"

```cpp
MemoryContextSwitchTo(MessageContext);
MemoryContextResetAndDeleteChildren(MessageContext);
exec_simple_query

	/* create and switch to TopTransactionContext */
	start_xact_command | StartTransactionCommand | StartTransaction | AtStart_Memory
		TopTransactionContext =  AllocSetContextCreate(TopMemoryContext, ...)
		CurTransactionContext = TopTransactionContext;
		MemoryContextSwitchTo(CurTransactionContext);

    /* ... */
    
	MemoryContextSwitchTo(MessageContext);
	pg_parse_query
	pg_analyze_and_rewrite_fixedparams
	pg_plan_queries


	CreatePortal
		portal->portalContext = AllocSetContextCreate(TopPortalContext, ...)

	PortalStart
		MemoryContextSwitchTo(PortalContext)
		CreateQueryDesc
		ExecutorStart | standard_ExecutorStart | standard_ExecutorStart
			estate = CreateExecutorState()
				qcontext = AllocSetContextCreate(CurrentMemoryContext, ...)
				MemoryContextSwitchTo(qcontext)
				estate = makeNode(EState);
				estate->es_query_cxt = qcontext

			MemoryContextSwitchTo(estate->es_query_cxt)
			InitPlan | ExecInitNode | ExecInitSeqScan

				/* create expression context for node */
				ExecAssignExprContext
					planstate->ps_ExprContext = CreateExprContext(estate);
						CreateExprContextInternal
							econtext->ecxt_per_tuple_memory = AllocSetContextCreate(estate->es_query_cxt, "ExprContext")
                            return econtext;
    /* ... */

	PortalRun
		MemoryContextSwitchTo(PortalContext)
		PortalRunSelect
            /* ... */

	PortalDrop
		portal->cleanup(portal);
			PortalCleanup
				ExecutorFinish
				ExecutorEnd | standard_ExecutorEnd | FreeExecutorState
					FreeExprContext
						MemoryContextDelete(econtext->ecxt_per_tuple_memory);
					MemoryContextDelete(estate->es_query_cxt);
		MemoryContextDelete(portal->portalContext);

	finish_xact_command | CommitTransactionCommand | CommitTransaction
		AtCommit_Memory
			MemoryContextSwitchTo(TopMemoryContext);
			MemoryContextDelete(TopTransactionContext);
```

## PortalRun

```cpp
PortalRun
    MemoryContextSwitchTo(PortalContext)
    PortalRunSelect
        ExecutorRun | standard_ExecutorRun
            MemoryContextSwitchTo(estate->es_query_cxt)
            printtup_startup
                /* a temporary memory context that we can reset once per row to recover palloc'd memory */
                myState->tmpcontext = AllocSetContextCreate(CurrentMemoryContext, "printtup", ...)
            ExecutePlan /* Loop until we've processed the proper number of tuples from the plan. */

                ResetPerTupleExprContext(estate); /* (estate)->es_per_tuple_exprcontext */

                ExecProcNode | ExecSeqScan | ExecScan
                    ResetExprContext(node->ps.ps_ExprContext);

                    /* get a tuple for(;;)*/
                    ExecProject
                        ExecEvalExprSwitchContext
                            oldContext = MemoryContextSwitchTo(econtext->ecxt_per_tuple_memory);
                            retDatum = state->evalfunc(state, econtext, isNull);
                            MemoryContextSwitchTo(oldContext);
                            return retDatum;
                printtup
                    /* Switch into per-row context so we can recover memory below */
                    oldcontext = MemoryContextSwitchTo(myState->tmpcontext);

                    /* send message, text/binary */

                    MemoryContextSwitchTo(QueryContext)
                    MemoryContextReset(myState->tmpcontext)
        dest->rShutdown(dest);
            printtup_shutdown
                MemoryContextDelete(myState->tmpcontext);
```
