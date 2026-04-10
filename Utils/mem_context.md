# MemoryContext 介绍

**MemoryContext = 带"一键清理"功能的内存分配器**

## MemoryContext

传统 malloc/free 独立分配释放，效率低、管理复杂。

PostgreSQL 通过 **MemoryContext** 实现按生命周期统一内存管理，提升效率与可靠性。`palloc`

## Context Tree

内存上下文层级结构

```

TopMemoryContext (后端生命周期)
├── ErrorContext          [出错备用] 错误消息/异常栈
├── CacheMemoryContext    [永久缓存] 计划/关系/类型缓存
├── TransactionContext    [事务级] 快照/事务状态/锁
├── MessageContext        [消息级] 原始语法树/消息缓冲区
└── PortalContext         [查询入口]
    └── QueryContext      [解析/规划] 查询树/执行计划
        └── ExprContext   [执行期] 表达式状态
            └── per_tuple_memory  [行级] 单行临时数据
```

## 关键特性

| 特性             | 说明                                     | 好处               |
| ---------------- | ---------------------------------------- | ------------------ |
| **树形结构**     | 子上下文随父上下文一起删除               | 批量清理，避免遗漏 |
| **生命周期绑定** | 上下文名 = 生命周期（Query/Transaction） | 代码意图清晰       |
| **隔离性**       | 不同上下文的内存互不干扰                 | 避免野指针/误释放  |
| **调试友好**     | 可打印内存使用统计                       | 方便排查泄漏       |

## 核心 API

```cpp
/* 创建 */
AllocSetContextCreate
	AllocSetContextCreateInternal
		MemoryContextCreate

/* 切换 */
MemoryContextSwitchTo

/* 删除 （递归删除所有子上下文 + 释放内存）*/
MemoryContextDelete

/* 重置 （释放所有内存，但保留上下文本身）*/
MemoryContextReset
```

## 类比文件系统

| **MemoryContext 概念**      | **文件系统类比**        | **说明**         |
| ------------------------- | ----------------- | -------------- |
| `MemoryContext`           | 目录 (Directory)    | 内存对象的容器        |
| `TopMemoryContext`        | 根目录 `/`           | 永远存在，所有目录的父节点  |
| `palloc()`                | `touch file`      | 在当前目录下创建文件     |
| `CurrentMemoryContext`    | `pwd`             | 新文件默认创建在这里     |
| `MemoryContextSwitchTo()` | `cd /path/to/dir` | 切换当前工作目录       |
| `MemoryContextDelete()`   | `rm -rf dir`      | 删除目录及旗下所有文件    |
| `MemoryContextReset()`    | `rm -rf dir/*`    | 清空内容，目录留着下次复用  |
| 子上下文                      | 子目录               | 父目录删除时，子目录自动被删 |
| 内存泄漏                      | 忘记删临时目录           | 文件残留，占用磁盘空间    |

## TopMemoryContext

```
TopMemoryContext
	ErrorContext
	Postmaster
	CacheMemoryContext
	TopPortalContext
	
TopMemoryContext (后端生命周期)
├── ErrorContext          [出错备用] 错误消息/异常栈
├── PostmasterContext     Postmaster 主进程专用, fork 后子进程
0988删除
├── CacheMemoryContext    [永久缓存] 计划/关系/类型缓存
├── TransactionContext    [事务级] 快照/事务状态/锁
├── MessageContext        [消息级] 原始语法树/消息缓冲区
└── PortalContext         [查询入口]
    └── QueryContext      [解析/规划] 查询树/执行计划
        └── ExprContext   [执行期] 表达式状态
            └── per_tuple_memory  [行级] 单行临时数据
```

```cpp
main
	MemoryContextInit
		TopMemoryContext = AllocSetContextCreate((MemoryContext) NULL, "TopMemoryContext", ALLOCSET_DEFAULT_SIZES);
		CurrentMemoryContext = TopMemoryContext;
		ErrorContext = AllocSetContextCreate(TopMemoryContext, "ErrorContext", 8 * 1024, 8 * 1024, 8 * 1024);
	PostmasterMain
		PostmasterContext = AllocSetContextCreate(TopMemoryContext, "Postmaster", ALLOCSET_DEFAULT_SIZES);
		MemoryContextSwitchTo(PostmasterContext);
		ServerLoop | BackendStartup | BackendRun
			MemoryContextSwitchTo(TopMemoryContext);
			PostgresMain
				InitPostgres
					RelationCacheInitialize
						CreateCacheMemoryContext
							CacheMemoryContext = AllocSetContextCreate
					InitCatalogCache
					EnablePortalManager
						TopPortalContext = AllocSetContextCreate
				MemoryContextDelete(PostmasterContext)
				MessageContext = AllocSetContextCreate(TopMemoryContext, ...)
				row_description_context = AllocSetContextCreate(TopMemoryContext, ...)

				MemoryContextSwitchTo(MessageContext);
				MemoryContextResetAndDeleteChildren(MessageContext);
```

## queries loop

```cpp
MemoryContextSwitchTo(MessageContext);
MemoryContextResetAndDeleteChildren(MessageContext);
exec_simple_query

	/* create and switch to TopTransactionContext */
	start_xact_command
		StartTransactionCommand
			StartTransaction
				AtStart_Memory
					TopTransactionContext =  AllocSetContextCreate(TopMemoryContext, ...)
					CurTransactionContext = TopTransactionContext;
					MemoryContextSwitchTo(CurTransactionContext);
		MemoryContextSwitchTo(CurTransactionContext);

	/* switch to: MessageContext */
	oldcontext = MemoryContextSwitchTo(MessageContext);
	pg_parse_query

	/* do something in CurTransactionContext */

	/* switch to: MessageContext */
	pg_analyze_and_rewrite_fixedparams
	pg_plan_queries


	CreatePortal
		portal->portalContext = AllocSetContextCreate(TopPortalContext, ...)
	PortalDefineQuery
	PortalStart
		MemoryContextSwitchTo(PortalContext)
		CreateQueryDesc
		ExecutorStart | standard_ExecutorStart | standard_ExecutorStart
			estate = CreateExecutorState()
				estate->es_query_cxt = AllocSetContextCreate(CurrentMemoryContext, ...)
				MemoryContextSwitchTo(qcontext)
				estate->es_query_cxt = qcontext

			/* switch to: QueryContext */
			MemoryContextSwitchTo(estate->es_query_cxt)
			InitPlan | ExecInitNode | ExecInitSeqScan

				/* create expression context for node */
				ExecAssignExprContext | CreateExprContext | CreateExprContextInternal
					econtext->ecxt_per_tuple_memory = AllocSetContextCreate(estate->es_query_cxt, "ExprContext")

		MemoryContextSwitchTo(PortalContext)

		MemoryContextSwitchTo(MessageContext)

	MemoryContextSwitchTo(TopTransactionContext)

	PortalRun
		MemoryContextSwitchTo(PortalContext)
		PortalRunSelect
			ExecutorRun | standard_ExecutorRun
				MemoryContextSwitchTo(estate->es_query_cxt)
				printtup_startup
					/* a temporary memory context that we can reset once per row to recover palloc'd memory */
					myState->tmpcontext = AllocSetContextCreate(CurrentMemoryContext, "printtup", ...)
				ExecutePlan

					/* Loop until we've processed the proper number of tuples from the plan. */
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

	PortalDrop
		portal->cleanup(portal);
			PortalCleanup
				ExecutorFinish
				ExecutorEnd
					standard_ExecutorEnd
						FreeExecutorState
							FreeExprContext
								MemoryContextDelete
							MemoryContextDelete(estate->es_query_cxt);
				FreeQueryDesc
		MemoryContextDelete(portal->portalContext);

	finish_xact_command
		CommitTransactionCommand
			CommitTransaction
				AtCommit_Memory
					MemoryContextSwitchTo(TopMemoryContext);
					MemoryContextDelete(TopTransactionContext);
```
