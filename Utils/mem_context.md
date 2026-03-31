# 🎯 PostgreSQL MemoryContext 深度指南

> **MemoryContext = 带"一键清理"功能的内存分配器**

---

## 调试

```cpp
#include "nodes/memnodes.h"
#include "utils/elog.h"

static inline MemoryContext
MemoryContextSwitchTo(MemoryContext context)
{
	const char *context_name = context ? (context->name ? context->name : "<unnamed>") : "<NULL>";
	elog(DEBUG2, "Switch to: %s", context_name);

	MemoryContext old = CurrentMemoryContext;

	CurrentMemoryContext = context;
	return old;
}


MemoryContextDelete(MemoryContext context)
{
	const char *context_name = context ? (context->name ? context->name : "<unnamed>") : "<NULL>";
	elog(DEBUG2, "Delete: %s",context_name);
	...
}

void
MemoryContextCreate(MemoryContext node,
					NodeTag tag,
					MemoryContextMethodID method_id,
					MemoryContext parent,
					const char *name)
{

	const char *context_name = name ? name : "<unnamed>";
	elog(DEBUG2, "Create: %s", context_name);
	...
}
```

```sql
SET log_min_messages = 'debug2';
```

## 一、为什么需要 MemoryContext？（先理解"为什么"）

### 传统 malloc/free 的问题

```c
// 场景：解析一条复杂 SQL，分配了 100 次内存
for (...) {
    node = malloc(sizeof(Node));  // 分配
    // ... 各种嵌套调用 ...
    if (error) {
        // 💥 怎么释放之前分配的 99 块内存？
        // 需要手动记录每个指针，容易遗漏 → 内存泄漏
        return;
    }
}
// 正常结束也要逐个 free，代码冗长易错
```

### PG 的解决方案：MemoryContext

```c
// 创建一个"查询上下文"
MemoryContext query_ctx = AllocSetContextCreate(...);

// 切换当前上下文
MemoryContextSwitchTo(query_ctx);

// 后续所有 palloc 都自动绑定到 query_ctx
node1 = palloc(sizeof(Node));  // ✅ 不用记指针
node2 = palloc(sizeof(Node));  // ✅ 不用记指针
// ... 分配 100 次 ...

// 查询结束/出错时：一键释放！
MemoryContextDelete(query_ctx);  // ✅ 100 块内存自动释放，无泄漏
```

> **设计哲学**：**按生命周期组织内存，而不是按分配点**

---

## 二、核心概念：上下文树（Context Tree）

### 📊 内存上下文层级结构

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

```cpp
MemoryContextSwitchTo(MessageContext);
MemoryContextResetAndDeleteChildren(MessageContext);
exec_simple_query
	start_xact_command
		StartTransactionCommand
			StartTransaction
				AtStart_Memory
					TopTransactionContext =  AllocSetContextCreate(TopMemoryContext, ...)
					CurTransactionContext = TopTransactionContext;
					MemoryContextSwitchTo(CurTransactionContext);
		MemoryContextSwitchTo(CurTransactionContext);
	oldcontext = MemoryContextSwitchTo(MessageContext);
	pg_parse_query()
	pg_analyze_and_rewrite_fixedparams
	pg_plan_queries

	CreatePortal
		portal->portalContext = AllocSetContextCreate(TopPortalContext, ...)
	PortalStart
		MemoryContextSwitchTo(PortalContext)
		ExecutorStart | standard_ExecutorStart | standard_ExecutorStart
			estate = CreateExecutorState()
				qcontext = AllocSetContextCreate(CurrentMemoryContext)
				MemoryContextSwitchTo(qcontext)
				estate->es_query_cxt = qcontext
			MemoryContextSwitchTo(estate->es_query_cxt)
			InitPlan | ExecInitNode | ExecInitSeqScan | ExecAssignExprContext
				CreateExprContext | CreateExprContextInternal
					econtext->ecxt_per_tuple_memory = AllocSetContextCreate
```

```
Create: TopTransactionContext
Switch to: MessageContext
Switch to: TopTransactionContext
Switch to: MessageContext
Create: PortalContext
Create: ExecutorState
Create: ExprContext
Switch to: TopTransactionContext
Create: printtup
Delete: printtup
Delete: ExprContext
Delete: ExecutorState
Delete: PortalContext
Delete: TopTransactionContext
Switch to: MessageContext
```
### 🔑 关键特性

| 特性             | 说明                                     | 好处               |
| ---------------- | ---------------------------------------- | ------------------ |
| **树形结构**     | 子上下文随父上下文一起删除               | 批量清理，避免遗漏 |
| **生命周期绑定** | 上下文名 = 生命周期（Query/Transaction） | 代码意图清晰       |
| **隔离性**       | 不同上下文的内存互不干扰                 | 避免野指针/误释放  |
| **调试友好**     | 可打印内存使用统计                       | 方便排查泄漏       |

---

## 核心 API 速查表

### 3.1 创建/删除

```c
// 创建标准分配集上下文（最常用）
MemoryContext ctx = AllocSetContextCreate(
    parent,           // 父上下文
    "MyContext",      // 名称（调试用）
    ALLOCSET_DEFAULT_SIZES  // 内存块大小策略
);

// 创建短生命周期上下文（自动清理优化）
MemoryContext ctx = AllocSetContextCreate(
    parent,
    "ShortLived",
    ALLOCSET_SMALL_SIZES  // 小块内存优化
);

// 删除上下文（递归删除所有子上下文 + 释放内存）
MemoryContextDelete(ctx);
```

### 3.2 切换/分配

```c
// 切换"当前上下文"（后续 palloc 都分配到这里）
MemoryContext old_ctx = MemoryContextSwitchTo(ctx);

// 分配内存（自动绑定到当前上下文）
void *ptr = palloc(size);
char *str = pstrdup("hello");  // 字符串专用
Node *node = palloc0(sizeof(Node));  // 清零版本

// 切回原上下文
MemoryContextSwitchTo(old_ctx);

// 在当前上下文分配（不切换）
void *ptr = MemoryContextAlloc(ctx, size);
```

### 3.3 释放/重置

```c
// ❌ 不要单独 free 单个 palloc 对象（除非用 pfree）
pfree(ptr);  // 可以，但很少用

// ✅ 推荐：重置上下文（释放所有内存，但保留上下文本身）
MemoryContextReset(ctx);  // 适合循环/批处理场景

// ✅ 推荐：删除上下文（释放内存 + 销毁上下文对象）
MemoryContextDelete(ctx);  // 适合生命周期结束
```

### 3.4 调试/监控

```c
// 打印上下文内存使用统计（开发调试用）
MemoryContextStats(TopMemoryContext);

// 检查指针属于哪个上下文（调试野指针）
MemoryContextGetParent(ctx);

// 设置内存分配失败回调（高级）
MemoryContextSetFailureHandler(ctx, handler);
```

### 3.5 类比文件系统

| **MemoryContext 概念**    | **文件系统类比**  | **说明**                     |
| ------------------------- | ----------------- | ---------------------------- |
| `MemoryContext`           | 目录 (Directory)  | 内存对象的容器               |
| `TopMemoryContext`        | 根目录 `/`        | 永远存在，所有目录的父节点   |
| `palloc()`                | `touch file`      | 在当前目录下创建文件         |
| `CurrentMemoryContext`    | `pwd`             | 新文件默认创建在这里         |
| `MemoryContextSwitchTo()` | `cd /path/to/dir` | 切换当前工作目录             |
| `MemoryContextDelete()`   | `rm -rf dir`      | 删除目录及旗下所有文件       |
| `MemoryContextReset()`    | `rm -rf dir/*`    | 清空内容，目录留着下次复用   |
| 子上下文                  | 子目录            | 父目录删除时，子目录自动被删 |
| 内存泄漏                  | 忘记删临时目录    | 文件残留，占用磁盘空间       |

---

## 实际场景：一条 SELECT 的内存生命周期

```
┌──────────────────────────────────────────────────────
│ 1. 连接建立
│    → 创建 PortalContext
├──────────────────────────────────────────────────────
│ 2. 收到 SQL: "SELECT * FROM users WHERE id = 1"
│    → 切换到 QueryContext
│    → parse_analyze(): palloc 语法树节点
│    → pg_plan_query(): palloc 执行计划节点
├──────────────────────────────────────────────────────
│ 3. Executor 执行
│    → 创建 ExprContext/TupleContext（子上下文）
│    → 每行结果：在 TupleContext 分配 → 发送 → Reset
│    → （循环中复用内存，避免频繁 malloc）
├──────────────────────────────────────────────────────
│ 4. 查询结束
│    → MemoryContextDelete(QueryContext)
│    → ✅ 所有 palloc 的内存一键释放，无泄漏
├──────────────────────────────────────────────────────
│ 5. 连接关闭
│    → MemoryContextDelete(PortalContext)
│    → ✅ 连接级资源全部清理
└──────────────────────────────────────────────────────
```

> 🔑 **关键观察**：
>
> - 每个阶段有明确的上下文边界
> - 子上下文用于"临时/循环"内存，父上下文用于"阶段"内存
> - 出错时直接删除上层上下文，自动清理所有子内存
