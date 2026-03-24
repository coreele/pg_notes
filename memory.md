# 内存

## PostgreSQL 内存上下文（MemoryContext）核心逻辑

1. **层级归属**：所有上下文构成以 `TopMemoryContext` 为根的树形结构，子上下文依赖父上下文存在，销毁父上下文会递归销毁所有子上下文；
2. **默认分配**：`CurrentMemoryContext` 指向当前默认上下文，未显式指定上下文的内存分配均使用它；
3. **生命周期管控**：短生命周期上下文（如查询/元组级）可一键重置/销毁，长生命周期上下文（如进程级）常驻，仅在进程退出时释放，核心目标是避免内存泄漏。

## 核心内存上下文的父子关系（树形结构）

以下是 PG 中最核心的上下文层级（按从根到叶的顺序，标注生命周期和核心用途）：

```text
TopMemoryContext（根，进程级永久）
├─ CacheMemoryContext（缓存专用，进程级永久）
│  └─ 各类缓存子上下文（如 relcache/catcache 附属数据，按需创建/销毁）
├─ ErrorContext（错误处理，会话级）
├─ PostmasterContext（仅主进程，进程级永久）
│  └─ ServerLoop 相关子上下文（连接监听，临时）
├─ BackendContext（后端进程核心，会话级）
│  ├─ MessageContext（消息处理，会话级）
│  ├─ PortalContext（门户/查询执行，查询级）
│  │  ├─ PerTupleContext（元组处理，元组级，处理完即重置）
│  │  └─ ExprContext（表达式计算，查询级）
│  ├─ TransactionContext（事务核心，事务级，提交/回滚重置）
│  │  └─ TempContext（事务临时数据，事务级）
│  └─ MemoryContext for Executor（执行器专用，查询级）
└─ UtilityContext（工具命令执行，如 CREATE TABLE，命令级）
```

## 关键上下文说明

| 上下文               | 父上下文         | 生命周期   | 核心作用                                                              |
| -------------------- | ---------------- | ---------- | --------------------------------------------------------------------- |
| `TopMemoryContext`   | 无（根）         | 进程级永久 | 所有上下文的根节点，仅进程退出时释放                                  |
| `CacheMemoryContext` | TopMemoryContext | 进程级永久 | 存储 relcache/catcache 核心结构，子上下文存缓存附属数据（可临时销毁） |
| `ErrorContext`       | TopMemoryContext | 会话级     | 存储错误信息，错误处理完成后可重置                                    |
| `BackendContext`     | TopMemoryContext | 会话级     | 后端进程（客户端连接）的核心上下文，会话断开时销毁                    |
| `TransactionContext` | BackendContext   | 事务级     | 事务执行的核心上下文，事务结束（提交/回滚）时重置                     |
| `PortalContext`      | BackendContext   | 查询级     | 单个查询执行的上下文，查询结束后销毁                                  |
| `PerTupleContext`    | PortalContext    | 元组级     | 处理单个元组的临时上下文，每个元组处理完即重置，避免内存堆积          |
