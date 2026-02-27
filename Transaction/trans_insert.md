# 事务管理

```sql
begin;
insert into tb values(1);
commit;
```

```cpp
static TransactionStateData TopTransactionStateData = {
	.state = TRANS_DEFAULT,
	.blockState = TBLOCK_DEFAULT,
	.topXidLogged = false,
};
```

## 1. `BEGIN;`

- **事务状态**：事务控制块（TopTransactionStateData）初始化其状态为 `TRANS_INPROGRESS`。
- **注意**：在 PG 中，执行 `BEGIN` 时通常还不会分配正式的事务 ID（XID），而是先分配一个 **虚拟事务 ID (VirtualXID)**，以节省 XID 资源。

```cpp
exec_simple_query
    start_xact_command
        StartTransactionCommand
            StartTransaction
                s->state = TRANS_START;
                /* initialize */
                s->state = TRANS_INPROGRESS;
            s->blockState = TBLOCK_STARTED;
    PortalRun | PortalRunMulti | PortalRunUtility | ProcessUtility | standard_ProcessUtility
        BeginTransactionBlock
            s->blockState = TBLOCK_BEGIN;
    finish_xact_command
        CommitTransactionCommand
            s->blockState = TBLOCK_INPROGRESS;
```

## **2. `INSERT INTO tb VALUES(1);`**

A. 元数据检索（Syscache / Relcache）

- 控制面必须先搞清楚 `tb` 是什么。它通过 **Syscache** 快速查询系统表（如 `pg_class`, `pg_attribute`），确定表的字段类型、是否有约束、是否有索引。

B. 逻辑锁定（Heavyweight Lock）

- **表级锁申请**：控制面调用 **Lock Manager**，申请 `tb` 的 `RowExclusiveLock`（行排他锁）。
- **作用**：防止你在插入时，另一个事务执行 `DROP TABLE`（控制面逻辑保护）。

C. 物理锁定与空间寻找（Data Buffer & FSM）

- **寻找空位**：访问 **FSM (Free Space Map)**，找到 `tb` 对应的数据面 Page。
- **Pin & Lock**：**Buffer Manager** 将该 Page 载入 **Shared Buffers**。为了物理安全，先对 Buffer 加 **Pin**（防止被换出），再加 **LWLock (轻量级锁)**（防止字节级冲突）。

D. 正式事务 ID 分配（XID & CLOG）

- 此时，控制面正式分配一个 **32 位的 XID**。

E. 生成数据变更（MVCC & WAL）

- **MVCC 标记**：在内存 Page 的元组头部写入数据 `1`，并将 `xmin` 设置为当前的 XID。
- **WAL 日志**：控制面生成一条 **WAL Record**（描述：在某 Page 插入了数据 1），并写入 **WAL Buffer**。

```cpp
exec_simple_query
    start_xact_command
        StartTransactionCommand
            break;
    parsetree_list = pg_parse_query(query_string);
    foreach(parsetree_item, parsetree_list)
        /* analyze and plan */
        start_xact_command
        pg_analyze_and_rewrite_fixedparams | parse_analyze_fixedparams
            transformTopLevelStmt | transformOptionalSelectInto | transformStmt | transformInsertStmt
                setTargetTable | table_openrv_extended | relation_openrv_extended | RangeVarGetRelid
                    LockRelationOid(relId, RowExclusiveLock);
        PortalRun | PortalRunMulti | ProcessQuery
            ExecutorStart | standard_ExecutorStart
                GetCurrentCommandId(true);
                    currentCommandIdUsed = true;
                    return currentCommandId;
            ExecutorRun | standard_ExecutorRun | ExecutePlan | ExecProcNode
                ExecModifyTable | ExecInsert | table_tuple_insert | heapam_tuple_insert
                    heap_insert
                        TransactionId xid = GetCurrentTransactionId();
        finish_xact_command
            CommitTransactionCommand
                CommandCounterIncrement
                    currentCommandId += 1;
                    currentCommandIdUsed = false;
                    SnapshotSetCommandId(currentCommandId);
    finish_xact_command /* This will only do something if the parsetree list was empty */
```

## 3. `COMMIT;`

这一步是确保“原子性”和“持久性”的关键。

A. 预写日志冲刷（WAL Flush - 持久性保证）

- 控制面调用操作系统指令（如 `fsync`），将 **WAL Buffer** 里的日志强制刷入磁盘。
- **核心逻辑**：只要 WAL 落地了，即便此时掉电，数据库重启后也能根据 WAL 重建数据面。

B. 状态变更（CLOG 更新 - 原子性保证）

- 在 **CLOG** 中将该 XID 的状态由 `IN_PROGRESS` 修改为 `COMMITTED`。
- **注意**：一旦 CLOG 状态改变，这个事务在逻辑上就“永久生效”了，其他事务通过 MVCC 判定就能看到这行数据。

C. 资源释放（Lock & Runtime Cleanup）

- **释放锁**：调用 `LockReleaseAll`，释放之前持有的 `RowExclusiveLock`（让别人可以改表结构）。
- **资源回收**：销毁事务级别的 **MemoryContext**，清理临时内存。
- **状态归位**：Backend 进程状态变回 `Idle`。

```cpp
exec_simple_query
    start_xact_command
        StartTransactionCommand
            break;
    PortalRun | PortalRunMulti | PortalRunUtility | ProcessUtility | standard_ProcessUtility
        EndTransactionBlock
            s->blockState = TBLOCK_END;
    finish_xact_command
        CommitTransactionCommand
            CommitTransaction
                s->state = TRANS_COMMIT;
                /* release */
                ResourceOwnerRelease | ResourceOwnerReleaseInternal
                    ProcReleaseLocks
                        LockReleaseAll(DEFAULT_LOCKMETHOD, !isCommit);
                s->state = TRANS_DEFAULT;
            s->blockState = TBLOCK_DEFAULT;
```

## 核心技术

| 步骤     | 涉及技术（控制面/运行面）     | 涉及技术（数据面）             | 目的               |
| -------- | ----------------------------- | ------------------------------ | ------------------ |
| `BEGIN`  | Transaction State, VirtualXID | -                              | 环境准备           |
| `INSERT` | Lock Manager, Syscache, XID   | Shared Buffer, FSM, WAL Buffer | 逻辑执行与物理写入 |
| `COMMIT` | CLOG, MVCC                    | Disk (WAL File)                | 状态确认与持久化   |

- **锁（Lock）** 保证了你执行时没人捣乱。
- **MVCC/CLOG** 保证了别人什么时候能看到你的修改。
- **WAL** 保证了你答应的修改绝对不会丢。
- **Buffer** 保证了你操作数据时的极致速度。
