# MemoryContext 介绍

## MemoryContext

基础 malloc/free 独立分配释放，效率低、管理复杂。(**相当于直接在根目录下管理文件**)

```cpp
void *malloc(size_t size);
void *realloc( void *ptr, size_t new_size);
void free( void *ptr );
```

PostgreSQL 通过 **MemoryContext** 实现按生命周期统一内存管理，提升效率与可靠性。`palloc` (**相当于在根目录下创建子目录独立管理**)

## 核心 API

```cpp
void *palloc(Size size);
void *repalloc(void *pointer, Size size);
void pfree(void *pointer);
```

### 上下文相关核心 API

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

| **MemoryContext 概念**    | **文件系统类比**  | **说明**                     |
| ------------------------- | ----------------- | ---------------------------- |
| `MemoryContext`           | 目录 (Directory)  | 内存对象的容器               |
| `TopMemoryContext`        | 根目录 `/`        | 永远存在，所有目录的父节点   |
| `palloc()`                | `touch file`      | 在当前目录下创建文件         |
| `CurrentMemoryContext`    | `pwd`             | 新文件默认创建在这里         |
| `MemoryContextSwitchTo()` | `cd /path/to/dir` | 切换当前工作目录             |
| `MemoryContextDelete()`   | `rm -rf dir`      | 删除目录及旗下所有文件       |
| `MemoryContextReset()`    | `rm -rf dir/*`    | 清空内容，目录留着下次复用   |
| `MemoryContextSetParent`  | `mv`              | 移动到其他上下文             |
| 子上下文                  | 子目录            | 父目录删除时，子目录自动被删 |
| 内存泄漏                  | 忘记删临时目录    | 文件残留，占用磁盘空间       |

## TopMemoryContext

```
TopMemoryContext (后端生命周期)
├── ErrorContext           用于错误恢复处理
├── PostmasterContext*     Postmaster 主进程专用（fork 后子进程删除）
├── CacheMemoryContext     缓存关系、系统表、CachedPlanSource(扩展协议)
├── MessageContext         处理单条消息，原始语法树/消息缓冲区
├── RowDescriptionContext* 构建列描述信息（扩展协议）
├── TopTransactionContext  存放生命周期和顶层事务一致的数据
└── TopPortalContext       管理查询执行实例 (Portal)，支持游标/分步获取/跨消息状态保持(扩展协议)
```

| 上下文名称                     | 内部数据有效生命周期     | 重置触发时机               |
| ------------------------- | -------------- | -------------------- |
| **MessageContext**        | **消息级** (几毫秒)  | 每条新消息到来前             |
| **TopTransactionContext** | **事务级** (几秒/分) | 事务 Commit/Rollback 后 |
| **TopPortalContext**      | **语句/游标级**     | 查询结束或 Cursor Close   |
| **CacheMemoryContext**    | **会话级/缓存失效**   | 显式失效或内存压力            |
| **ErrorContext**          | **错误处理期间**     | 错误处理完后手动重置           |

> `PostmasterContext` 仅存在于 Postmaster 主守护进程中，普通后端进程 (Backend) 无此上下文。

### 起步阶段

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

### 执行阶段

```
TopPortalContext
└── PortalContext
	└── QueryContext
		└── ExprContext
			├── printtup
			└── per_tuple_memory
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
