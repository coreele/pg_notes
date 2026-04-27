# Memory TopMemoryCtx

```
TopMemoryContext (后端生命周期)
├── ErrorContext           用于错误恢复处理
├── PostmasterContext*     Postmaster 主进程专用(fork 后子进程删除)
├── CacheMemoryContext     缓存关系、系统表、CachedPlanSource(扩展协议)
├── TopPortalContext       管理查询执行实例(Portal)，支持游标/分步获取/跨消息状态保持
├── MessageContext         处理单条消息，原始语法树/消息缓冲区
├── RowDescriptionContext  构建列描述信息(扩展协议)
└── TopTransactionContext  存放生命周期和顶层事务一致的数据
```

| 上下文名称                | 内部数据有效生命周期 | 重置触发时机            |
| ------------------------- | -------------------- | ----------------------- |
| **ErrorContext**          | **错误处理期间**     | 错误处理完后手动重置    |
| **CacheMemoryContext**    | **会话级/缓存失效**  | 显式失效或内存压力      |
| **MessageContext**        | **消息级** (几毫秒)  | 每条新消息到来前        |
| **TopTransactionContext** | **事务级** (几秒/分) | 事务 Commit/Rollback 后 |
| **TopPortalContext**      | **语句/游标级**      | 查询结束或 Cursor Close |

> `PostmasterContext` 仅存在于 Postmaster 主守护进程中，普通后端进程 (Backend) 无此上下文。

## boot 相关上下文

```cpp
main
	MemoryContextInit
		TopMemoryContext = AllocSetContextCreate((MemoryContext) NULL, ...);
		CurrentMemoryContext = TopMemoryContext;
		ErrorContext = AllocSetContextCreate(TopMemoryContext, ...);
	PostmasterMain
		PostmasterContext = AllocSetContextCreate(TopMemoryContext, ...);
		MemoryContextSwitchTo(PostmasterContext);
		ServerLoop | BackendStartup | BackendRun

            /* child process */
			MemoryContextSwitchTo(TopMemoryContext);
			PostgresMain
				InitPostgres
					RelationCacheInitialize | CreateCacheMemoryContext
						CacheMemoryContext = AllocSetContextCreate(TopMemoryContext, ...)
					InitCatalogCache
					EnablePortalManager
						TopPortalContext = AllocSetContextCreate(TopMemoryContext, ...)
				MemoryContextDelete(PostmasterContext) // delete postmaster in child context
				MessageContext = AllocSetContextCreate(TopMemoryContext, ...)
				row_description_context = AllocSetContextCreate(TopMemoryContext, ...) // for RowDescription messages

                for (;;) /* queries loop */
	            {
                    MemoryContextSwitchTo(MessageContext);
                    MemoryContextResetAndDeleteChildren(MessageContext);

                    exec_simple_query(query_string);
                }
```
