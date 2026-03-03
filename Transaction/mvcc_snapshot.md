# MVCC机制核心：快照

## 0. 核心用例设计

假设表 `accounts` 中有一条初始数据：`id=1, balance=100`，其事务 ID（XID）为 `500`。

现在有两个并发事务：

- **事务 A (XID 601)**：隔离级别为 `READ COMMITTED`。
- **事务 B (XID 602)**：执行 `UPDATE balance = 200`，但尚未提交。

```sql
create table accounts(id int, balance int);
insert into accounts values (1, 500);
```

| client 1                        | client 2                                          |
| ------------------------------- | ------------------------------------------------- |
| `begin;`                        | `begin;`                                          |
|                                 | `update accounts set balance = 200 where id = 1;` |
| `select * from accounts; --500` |                                                   |
|                                 | `commit;`                                         |
| `select * from accounts; --200` |                                                   |
| `commit;`                       |                                                   |

- 默认隔离级别为 `read committed`，只有 client 2 提交就可以读到最新结果，因此存在不可重复读问题
- 将隔离级别修改为 `repeatable read` 读取结果一致

| client 1                                             | client 2                                          |
| ---------------------------------------------------- | ------------------------------------------------- |
| `start transaction isolation level repeatable read;` | `begin;`                                          |
|                                                      | `update accounts set balance = 200 where id = 1;` |
| `select * from accounts; --500`                      |                                                   |
|                                                      | `commit;`                                         |
| `select * from accounts; --500`                      |                                                   |
| `commit;`                                            |                                                   |

当指定隔离界别为 `repeatable read`, 两次读取数据相同，实现可重复读，且由于快照隔离的天然特性，也不存在幻读问题；实现方式：**快照！**

## 1. Snapshot 数据结构关键字段

在源码中，快照由 `SnapshotData` 结构体表示。它的核心就像一张“合影”，记录了那一刻全系统的事务状态。

- **`xmin`**：最早的活跃事务 ID。所有 XID < xmin 的事务都已经完成了（提交或回滚），它们的数据对该快照**一定可见**。
- **`xmax`**：快照发放时，系统分配过的最大 XID + 1。所有 XID ≥ xmax 的事务在拍照片时还没出生，其数据对该快照**一定不可见**。
- **`xip[]` (Transaction ID Array)**：在 `xmin` 和 `xmax` 之间的“灰色地带”，记录了拍照那一刻**正在运行**的事务 ID 列表。

## 2. 行的可见性判定逻辑

每一行数据（HeapTuple）头部都有 `t_xmin`（插入者的 XID）和 `t_xmax`（删除/更新者的 XID）。基本方式如下：

1. **看插入者 (`t_xmin`)**：

- 如果 `t_xmin` 在快照中是“已提交”的，且不在 `xip[]` 列表中，说明插入已生效。

2. **看删除者 (`t_xmax`)**：

- 如果 `t_xmax` 为 0，说明没被删除，可见。
- 如果 `t_xmax` 在快照中是“活跃”的或“未出生”的，说明删除动作还没生效，可见。
- 如果 `t_xmax` 在快照中是“已提交”的，说明行已过期，不可见。

## 3. GetTransactionSnapshot() 的调用时机

隔离级别决定了“拍照”的频率：

- **READ COMMITTED**：**每条 SQL 语句**执行前都会调用一次。所以你能看到其他事务刚提交的修改。
- **REPEATABLE READ / SERIALIZABLE**：只在事务的**第一条 SQL** 执行前调用一次，后续整段事务都复用这张旧照片。

  ```cpp
  	if (IsolationUsesXactSnapshot()) /* 根据隔离级别判断是否复用快照 */
		return CurrentSnapshot;

	/* Don't allow catalog snapshot to be older than xact snapshot. */
	InvalidateCatalogSnapshot();

	CurrentSnapshot = GetSnapshotData(&CurrentSnapshotData);

	return CurrentSnapshot;
  ```

## 4. 活跃事务数组 (`ProcArray`)

- **作用**：它是快照数据的**源泉**。维护在共享内存中，记录了当前所有连接正在运行的 XID。
- **事务开始**：进程将自己的 XID 填入 `ProcArray`。
- **事务结束**：`CommitTransaction` 或 `AbortTransaction` 的最后阶段，进程将自己从 `ProcArray` 中移除。

## 5. 核心函数(`GetSnapshotData`)

```cpp
/* 
 * The returned snapshot includes xmin (lowest still-running xact ID),
 * xmax (highest completed xact ID + 1), and a list of running xact IDs
 * in the range xmin <= xid < xmax.  It is used as follows:
 *		All xact IDs < xmin are considered finished.
 *		All xact IDs >= xmax are considered still running.
 *		For an xact ID xmin <= xid < xmax, consult list to see whether
 *		it is considered running or not.
 * This ensures that the set of transactions seen as "running" by the
 * current xact will not change after it takes the snapshot.
 */
```

获取 xmax 和 xmin:

```cpp
xmax = XidFromFullTransactionId(latest_completed);
TransactionIdAdvance(xmax);

/* initialize xmin calculation with xmax */
xmin = xmax;

for (int pgxactoff = 0; pgxactoff < numProcs; pgxactoff++)
{
	if (NormalTransactionIdPrecedes(xid, xmin))
		xmin = xid;
	/* Add XID to snapshot. */
	xip[count++] = xid;
}
```
