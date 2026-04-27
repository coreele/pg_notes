# Transaction XID

https://www.interdb.jp/pg/pgsql05/01.html

- **VXID** 是事务在内存中的临时工牌
- **XID (Transaction ID)** 就是写入数据页（Page Header）和日志（WAL）的“永久烙印”
- **XID** 是 PostgreSQL 实现多版本并发控制（MVCC）与数据持久化的基石

## 1. 分配时机：按需升级

与 VXID 随事务启动即分配不同，XID 的分配遵循**延迟加载**原则：

- **只读事务**：永不分配 XID，仅持有 VXID。
- **写事务**：只有在事务产生**数据变更**（INSERT/UPDATE/DELETE）的瞬间，才会调用 `GetNewTransactionId()` 获取一个全局唯一的 XID。
- **设计意图**：保护有限的 XID 序列空间，减少非必要的全局锁（XidGenLock）竞争。

## 2. 物理特性：落盘的可见性标识

XID 是一个 32 位的无符号整数，它在数据面（Data Plane）承担双重任务：

- **行级标记**：每一行数据（Tuple）的头部都存有 `xmin`（创建该行的 XID）和 `xmax`（删除该行的 XID）。
- **可见性判定**：通过对比当前快照与行头部的 XID，数据库在**不加读锁**的情况下，确定该行对当前事务是否可见。

## 3. 核心约束：事务回卷

由于 XID 仅有 32 位，其取值范围约为 **0 到 42 亿**。这带来了数据库内核最沉重的治理任务：**事务回卷（Wraparound）**。

![](assets/transID_Wraparound.png)

- **逻辑环**：XID 被视为一个循环圆环。环中逆时针方向的 **21 亿**个数字被定义为“过去”。环中顺时针方向的 **21 亿**个数字被定义为“未来”。
- **冷冻（Freeze）**：为了防止新旧事务混淆，系统必须通过 `VACUUM FREEZE` 将老旧的 XID 转换为特殊的特殊标识（Frozen XID, 2），确保它们永远被视为“过去”。

## 4. 存储开销：CLOG (Commit Log)

XID 的状态（提交、回滚、运行中）并不记录在数据页，而是维护在 **CLOG**（又称 `pg_xact`）中：

- 每个 XID 在 CLOG 中占用 2 个比特位。
- **查询逻辑**：当引擎看到数据页上的 XID 时，会立刻去 CLOG 查找其最终结局，从而决定是否加载该行数据。

## 5. 核心函数 `GetCurrentTransactionId`

```cpp
/*
 *	GetCurrentTransactionId
 *
 * This will return the XID of the current transaction (main or sub
 * transaction), assigning one if it's not yet set.  Be careful to call this
 * only inside a valid xact.
 */
TransactionId
GetCurrentTransactionId(void)
{
	TransactionState s = CurrentTransactionState;

	if (!FullTransactionIdIsValid(s->fullTransactionId))
		AssignTransactionId(s); // Assigns a new permanent FullTransactionId to the given TransactionState
	return XidFromFullTransactionId(s->fullTransactionId);
}
```

## 6. 总结：VXID 与 XID 的权责对等

| 特性      | **VXID (控制面)** | **XID (数据面)**         |
| ------- | -------------- | --------------------- |
| **本质**  | 内存标识，处理并发冲突    | 磁盘标识，处理数据版本           |
| **持久化** | 随进程结束消失        | 永久写入 WAL 和 Page       |
| **全局性** | 局部唯一（进程内）      | 全局递增（实例级）             |
| **成本**  | 几乎为零           | 昂贵（触发 I/O、占用存储、需回卷治理） |

