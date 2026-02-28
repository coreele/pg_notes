# 深度理解 PostgreSQL 虚拟事务 ID (VXID)

- 在 PostgreSQL 的事务系统中，**VXID (Virtual Transaction ID)** 是控制面（Control Plane）实现资源解耦与并发性能的核心设计。
- 相比于落盘的物理事务 ID (XID)，VXID 是一种仅存在于内存中的**轻量级身份标识**。

## 1. 物理结构与组成

```cpp
typedef struct
{
	BackendId	backendId;		/* backendId from PGPROC */
	LocalTransactionId localTransactionId;	/* lxid from PGPROC */
} VirtualTransactionId;
```

VXID 的表现形式通常为 `BackendID / LocalTransactionID`（例如 `3/29`）：

- **BackendID**：该后端进程在共享内存 `ProcArray` 数组中的槽位索引。
- **LocalTransactionID**：该进程内部自增的 32 位序列号，记录该进程自启动以来处理的事务总数。

## 2. VXID 获取时机

- 当一个会话（Session）发送一条 SQL 时，执行引擎会进入 StartTransactionCommand
- Backend 进程从自己的私有内存（局部变量）中获取 nextLocalTransactionId 并自增
- 将当前进程的 BackendId（ProcArray 数组下标）与该计数值组合，生成如 3/29 的 VXID
- 记录 lxid 到 MyProc

```cpp
/*
 * Assign a new LocalTransactionId, and combine it with the backendId to
 * form a virtual transaction id.
 */
vxid.backendId = MyBackendId;
vxid.localTransactionId = GetNextLocalTransactionId();

/*
 * Lock the virtual transaction id before we announce it in the proc array
 */
VirtualXactLockTableInsert(vxid);
MyProc->lxid = vxid.localTransactionId;
```

## 3. 设计意图：减少物理 XID 分配

VXID 的存在是为了推迟并减少物理 XID 的分配。

- **降低全局竞争**：只读事务（SELECT）仅持有 VXID。只有当事务触发数据修改（INSERT/UPDATE/DELETE）时，内核才会通过 `GetNewTransactionId()` 申请全局唯一的物理 XID。
- **延缓 XID 耗尽**：由于 VXID 不记录在磁盘（WAL 或数据页），它不占用 4 亿有限的 XID 空间，从根本上缓解了事务号回卷（Wraparound）的压力。

## 4. 运行面约束：基于 VXID 的锁定机制

VXID 在 **`pg_locks`** 视图中承担着关键的“占位”角色：

- **自我宣告**：每个事务启动后，会自动持有一把类型为 `virtualxid` 的 `ExclusiveLock`。
- **依赖等待**：当其他进程（如 `VACUUM` 或 `HOT` 清理）需要确认某个旧事务是否结束时，它会尝试获取该 VXID 的共享锁。
- **逻辑闭环**：无法获取锁意味着事务仍在运行；成功获取则代表该进程的控制逻辑已结束，相关旧版本快照可安全回收。

## 5. 查询 vxid

```sql
CREATE OR REPLACE VIEW vw_vxid AS
SELECT
    l.pid,
    l.virtualxid AS vxid,
    a.backend_xid AS xid,
    a.state,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE l.locktype = 'virtualxid'  -- 只看宣告身份的那一行
  AND l.granted = true;          -- 只看锁的持有者
```

| client 1                                   | client 2                             |
| ------------------------------------------ | ------------------------------------ |
|                                            | `begin;`                             |
|                                            | `select pg_backend_pid(); --18479`   |
| `select * from vw_vxid where pid = 18479;` |                                      |
| `select pg_stat_get_backend_pid(10);`      |                                      |
|                                            | `select txid_current_if_assigned();` |
|                                            | `insert into tb values(1);`          |
| `select * from vw_vxid where pid = 18479;` |                                      |
|                                            | `select txid_current_if_assigned();` |
|                                            | `commit;`                            |


> [!NOTE] 注意
> 事务开始时即分配 vxid，但无 xid，执行插入数据时，内核分配 xid

## 总结

VXID 是 PostgreSQL 实现“**读不阻塞写**”以及“**轻量级事务管理**”的基石。