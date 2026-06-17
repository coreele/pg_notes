# Executor

## 执行器生命周期

| 阶段     | 核心函数                 | 关键动作                      | 节点操作                                            |
| :----- | :------------------- | :------------------------ | :---------------------------------------------- |
| Init   | `ExecutorStart` <br> | 解析计划树，构建运行时状态树，打开表，编译表达式。 | `ExecInitNode`: `Plan` -> `PlanState`<br>       |
| Run    | `ExecutorRun` <br>   | 循环拉取数据，逐行处理，发送给客户端        | `ExecProcNode`: `TupleTableSlot`, `ExprContext` |
| Finish | `ExecutorFinish`     | 执行排队的 AFTER 触发器，更新统计信息    | `AfterTriggerEndQuery`                          |
| End    | `ExecutorEnd` <br>   | 关闭文件/扫描描述符，销毁临时占用资源       | `ExecEndNode`                                   |

## 执行流程梳理

```c
/* ... */

/* Portal & Executor */
CreatePortal

PortalDefineQuery // portal->stmts = plantree_list;

PortalStart // Prepare a portal for execution. params, strategy, queryDesc
	ExecutorStart // prepare the plan for execution
		standard_ExecutorStart
			InitPlan /* Initialize the plan state tree */
				**ExecInitNode** | ExecInitSeqScan
					ExecOpenScanRelation
	PORTAL_READY

PortalRun | PortalRunSelect

	/* Executor */
	ExecutorRun | tandard_ExecutorRun | ExecutePlan // Processes the query plan until retrieved 'numberTuples' tuples
		**ExecProcNode** | ExecSeqScan
			ExecScan | ExecScanFetch | SeqNext // executor module
				/* Access + Storage*/
				table_scan_getnextslot | heap_getnextslot | heapgettup_pagemode
					heapgetpage | ReadBufferExtended | ReadBuffer_common
PortalDrop
	PortalCleanup
		ExecutorFinish
			ExecPostprocessPlan
			AfterTriggerEndQuery
		ExecutorEnd
			ExecEndPlan
				**ExecEndNode** | ExecEndSeqScan
		FreeQueryDesc
```

