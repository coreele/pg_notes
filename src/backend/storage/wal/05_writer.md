# WAL Writer & WAL Flush

## WAL 写入路径架构

```
  用户后端 (Backend)
     │
     ├─ XLogInsert()               ← WAL 记录 → WAL Buffer (共享内存)
     │     │
     │     └─ XLogFlush(lsn)       ← 同步提交: 等待 WAL 刷到磁盘
     │           │
     │           └─ issue_xlog_fsync()
     │
     ▼
  用户后端 (Backend) — 或 — WAL Writer 进程
     │                    │
     │ (同步 flush)        │ (异步 flush)
     ▼                    ▼
  write() 系统调用      write() 系统调用
     │                    │
     ▼                    ▼
  PG 的 WAL 文件       PG 的 WAL 文件
     │                    │
     ▼ (同步提交时)        ▼ (wal_writer_delay 到期或 idle)
  fsync() / fdatasync()  fsync()
```

---

## 1. WAL Buffer — 共享内存环形缓冲

```c
// xlog.c

typedef struct XLogCtlData {
    XLogRecPtr      Insert;             // 当前插入位置 (逻辑 LSN)
    XLogRecPtr      Write;              // 已 write() 到 OS 的位置
    XLogRecPtr      Flush;              // 已 fsync() 到磁盘的位置

    XLogRecPtr      LastSegSwitchLSN;   // 上次段切换的 LSN
    XLogSegNo       lastSegSwitchedTLI; // 最近使用的 WAL 段号

    char           *pages;              // WAL Buffer 内存 (大小: wal_buffers)
    XLogRecPtr     *xlblocks;           // 每个 WAL Buffer 页的结束 LSN

    WALInsertLock  *WALInsertLocks;     // 并发插入锁 (8个)

    // WAL Writer 通信
    Latch           WALWriteLatch;      // WAL Writer 的等待锁存器
    slock_t         info_lck;           // 保护 WAL 统计信息

    TimeLineID      ThisTimeLineID;
    // ...
} XLogCtlData;

static XLogCtlData *XLogCtl = NULL;     // 共享内存中的全局实例
```

### 关键位置指针

```
WAL 流:
                                    Insert → 内存中已插入但可能未写入
                              Write → 已 write() 到 OS page cache
                        Flush → 已 fsync() 到磁盘

  [已刷盘区域][OS Cache中][WAL Buffer中待写][WAL Buffer空闲]
  ──────────┬──────────┬─────────────────┬─────────────────►
            ↑          ↑                 ↑
          Flush      Write            Insert
```

**保证关系**: `Flush ≤ Write ≤ Insert`

### wal_buffers 配置

```sql
-- wal_buffers: WAL Buffer 大小
-- 默认 -1 (auto = shared_buffers / 32, 最小 64KB, 最大 16MB)
SHOW wal_buffers;
-- 典型值: 16MB (一个完整 WAL 段)
```

WAL Buffer 是一个**环形缓冲区**。当 `Insert` 位置接近 `Flush` 位置且没有足够空间时，插入者必须等待 WAL 被刷盘。

---

## 2. WAL Writer 进程

```c
// xlog.c

void WalWriterMain(void) {
    XLogRecPtr  last_flush_pos = GetFlushRecPtr(NULL);

    for (;;) {
        // 1. 检查是否需要刷盘
        XLogRecPtr flush_to = GetFlushRecPtr(&Write);

        if (flush_to != InvalidXLogRecPtr && flush_to > last_flush_pos) {
            // WAL 有待刷盘的数据
            XLogWrite(openLogFile, flush_to, last_flush_pos);
            last_flush_pos = flush_to;
        }

        // 2. 计算等待时间
        long wait_time = WalWriterDelay;   // wal_writer_delay (默认 200ms)

        // 3. 在 latch 或超时上等待
        int rc = WaitLatch(MyLatch,
                          WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
                          wait_time, WAIT_EVENT_WAL_WRITER_MAIN);

        if (rc & WL_LATCH_SET) {
            ResetLatch(MyLatch);
            // 被 XLogInsert 或 commit 唤醒 → 立即尝试刷盘
        }
        // 否则: 超时 → 周期性刷盘
    }
}
```

### WAL Writer 的工作周期

```
                        wal_writer_delay (默认 200ms)
  ┌──────────────────────────────────────────────────┐
  │                                                   │
  ▼                                                   ▼
 [WAL Writer 醒来]
   │
   ├─ 自上次刷新后 Insert 向前移动 ≥ wal_writer_flush_after (默认 1MB)?
   │    ├─ 是 → 立即 XLogWrite() (write + fsync)
   │    └─ 否 → 检查是否有异步提交待刷新
   │
   ├─ 距上次刷新 ≥ wal_writer_delay?
   │    └─ 是 → XLogWrite() 到 Write 位置
   │
   └─ WaitLatch(wal_writer_delay) → 睡眠
        │
        └─ 被 latch 唤醒? (XLogInsert 触发) → 立即醒来
```

### 相关 GUC 参数

| 参数 | 默认值 | 说明 |
|------|-------|------|
| `wal_writer_delay` | 200ms | WAL Writer 唤醒间隔 |
| `wal_writer_flush_after` | 1MB | 累积多少 WAL 数据后触发一次 OS flush |

---

## 3. XLogFlush — 同步刷盘

当需要保证 WAL 已持久化到磁盘时 (如事务提交、checkpoint)，后端调用 `XLogFlush`：

```c
// xlog.c (简化逻辑)

void XLogFlush(XLogRecPtr record) {
    XLogRecPtr  WriteRqstPtr;
    XLogRecPtr  FlushRqstPtr;

    // 快速路径: 如果请求 LSN 已经刷盘，直接返回
    if (record <= GetFlushRecPtr(NULL))
        return;

    // 1. 确定需要刷盘的范围
    SpinLockAcquire(&XLogCtl->info_lck);
    WriteRqstPtr = XLogCtl->Insert;   // 写入到此位置
    FlushRqstPtr = record;             // 刷盘到此位置 (至少)
    SpinLockRelease(&XLogCtl->info_lck);

    // 2. 先 write() (如果 Write < WriteRqstPtr)
    if (Write < WriteRqstPtr) {
        Write = XLogWrite(openLogFile, WriteRqstPtr, Write);
        // XLogWrite 内部调用 write() 系统调用
    }

    // 3. 再 fsync() (如果 Flush < record)
    if (GetFlushRecPtr(NULL) < record) {
        // issue_xlog_fsync 调用 fsync()/fdatasync()
        issue_xlog_fsync(openLogFile, openLogSegNo);
        XLogCtl->Flush = record;
    }
}
```

### XLogWrite — 写入到 OS

```c
// xlog.c (简化)

static XLogRecPtr XLogWrite(XLogwrtRqst WriteRqst,
                             TimeLineID tli,
                             bool flexible) {
    XLogRecPtr  startpos = openLogSegNo * XLogSegSize + openLogOff;
    XLogRecPtr  endpos   = WriteRqst.Write;

    while (startpos < endpos) {
        // 1. 计算本次可以写入的字节数
        int nbytes = endpos - startpos;
        int segbytes = XLogSegSize - startpos % XLogSegSize;
        nbytes = Min(nbytes, segbytes);

        // 2. 从 WAL Buffer 复制到写缓冲区，或直接 write()
        nwritten = write(openLogFile, from, nbytes);

        startpos += nwritten;
    }

    // 3. 如果请求了 flush: issue_xlog_fsync()
    if (WriteRqst.Flush > 0) {
        issue_xlog_fsync(openLogFile, openLogSegNo);
    }

    return startpos;
}
```

---

## 4. 同步提交 vs 异步提交

### 同步提交 (synchronous_commit = on / remote_write / remote_apply)

```c
// transam.c: RecordTransactionCommit

static void RecordTransactionCommit(void) {
    // ... XLogInsert 写入 COMMIT 记录 ...

    if (synchronous_commit == SYNCHRONOUS_COMMIT_ON) {
        // 同步: 等待 WAL 刷盘
        XLogFlush(XactLastRecEnd);
    }
    // 否则: 不等待 WAL 刷盘 → 异步提交

    // 标记事务为已完成
    TransactionIdCommitTree(xid, nxids, children);
}

// 在 WAL Commit 之后，在写入 CLOG 之前:
static void TransactionIdCommitTree(...) {
    // 必须确保 WAL 在 CLOG 之前刷盘 (WAL 先于数据规则)
    // 对于异步提交: 在写入 CLOG 页面时检查
    if (XactLastRecEnd != InvalidXLogRecPtr)
        XLogFlush(XactLastRecEnd);  // 如果有异步 commit，这里也会触发
}
```

### 异步提交 (synchronous_commit = off)

```c
// 异步提交流程:
RecordTransactionCommit() {
    XLogInsert(RM_XACT_ID, XLOG_XACT_COMMIT);
    // 记录 WAL LSN
    XactLastRecEnd = ProcLastRecPtr;

    if (synchronous_commit == SYNCHRONOUS_COMMIT_OFF) {
        // 只记录 LSN，不等待刷盘
        // WAL Writer 会在最多两次 wal_writer_delay (400ms) 内刷盘
    }
    // 返回给客户端: 事务"已完成"
}

// WAL Writer 稍后:
WalWriterMain() {
    // 检查是否有未刷盘的异步提交
    if (async_commit_lsn > last_flush_lsn) {
        XLogWrite(openLogFile, async_commit_lsn, last_flush_lsn);
    }
}
```

### synchronous_commit 参数详解

| 值 | 含义 | 何时返回给客户端 | 数据丢失风险 |
|---|------|----------------|------------|
| `on` (默认) | 主库 WAL 刷盘 | fsync 完成后 | 无 (除非磁盘故障) |
| `remote_apply` | 备库应用完成 | 备库 WAL 应用后 | 无 |
| `remote_write` | 备库写入 OS | 备库 OS write 后 | 备库 OS 崩溃时丢失 |
| `on` | 主库 WAL 刷盘 |fsync 完成后 | 无 |
| `local` | 主库 WAL 刷盘 | fsync 完成后 | 无 (不影响备库) |
| `off` | 主库 WAL Buffer 写入 | 写入 WAL Buffer 后立即返回 | 主库崩溃时丢失 |

```
远程模式 (remote_apply, remote_write):
  主库                       备库
  ┌──┐    WAL Stream      ┌──┐
  │  │ ──────────────────→ │  │
  │  │                     │  │ remote_write: 备库收到 WAL 后即返回
  │  │                     │  │ remote_apply: 备库应用后返回
  └──┘                     └──┘
```

---

## 5. WAL 在 Buffer Manager 中的交互

当 Buffer Manager 需要写出一个脏页时，必须确保该页的 WAL 已刷盘：

```c
// bufmgr.c: FlushBuffer

static void FlushBuffer(BufferDesc *buf, SMgrRelation reln) {
    XLogRecPtr  recptr;
    Page        page = BufferGetPage(buf);

    // 获取页面 LSN
    recptr = PageGetLSN(page);

    // WAL 先于数据规则: 确保该页面的 WAL 已刷盘
    XLogFlush(recptr);

    // 现在安全了: 写入页面
    smgrwrite(reln, buf->tag.forkNum, buf->tag.blockNum,
              (char *) page, true);
}
```

**这就是 WAL 的"先写日志"规则的具体实现**：页面的 LSN 是影响该页的最新 WAL 记录的地址。在刷出页面之前，必须确保直到该 LSN 的所有 WAL 都已持久化。

---

## 6. WAL 段切换

当 `Insert` 位置到达当前 WAL 段的末尾 (每 16MB)，发生 WAL 段切换：

```c
// xlog.c: AdvanceXLInsertBuffer

static void AdvanceXLInsertBuffer(XLogRecPtr upto, bool opportunistic) {
    XLogRecPtr  NewPageBeginPtr;
    XLogRecPtr  NewPageEndPtr;

    NewPageBeginPtr = XLogCtl->xlblocks[bytepos];
    NewPageEndPtr   = NewPageBeginPtr + XLOG_BLCKSZ;

    if (NewPageEndPtr % XLogSegSize == 0) {
        // 段边界: 需要切换到新的 WAL 段文件

        // 1. 创建新段文件
        XLogFileInit(XLogSegmentOffset(...), ...);

        // 2. 填充页头
        XLogPageHeader *pagehdr = ...;
        pagehdr->xlp_magic = XLOG_PAGE_MAGIC;

        // 3. 通知 archiver (如果有)
        XLogArchiveNotify(...);
    }
}
```

### WAL 段切换的触发原因

| 触发条件 | 说明 |
|---------|------|
| **自然到达 16MB 边界** | 正常写入到段末尾 |
| **手动触发** | `pg_switch_wal()` 函数 |
| **archive_timeout** | 达到 `archive_timeout` 时间 (默认 0=不强制) |
| **pg_basebackup** | 备份开始/结束时 |

---

## 7. WAL 刷新性能考量

### fsync 问题

`fsync()` 是昂贵的系统调用。PostgreSQL 使用以下策略减少 fsync 次数：

1. **WAL Writer 批量化**：后台进程批量 fsync，而不是每个后端单独 fsync
2. **异步提交**：不需要 fsync 即可返回给客户端
3. **组提交 (Group Commit)**：多个事务的提交记录在同一个 WAL flush 中批量持久化

### 组提交

```
时间线:
  Backend A: XLogInsert(COMMIT_A) → XLogFlush(A) → ...
  Backend B:     XLogInsert(COMMIT_B) → XLogFlush(B) ──┐
  Backend C:         XLogInsert(COMMIT_C) → XLogFlush(C)─┤
                                                        │
                    所有三个提交被同一个 fsync() 刷盘 ←───┘
```

`XLogFlush` 会刷盘到**至少**请求的 LSN，但通常实际刷盘位置会更远 (因为 WAL Writer 或另一个后端可能已经推进了 Write 位置)。这是组提交的自然实现。

### wal_sync_method

```sql
-- 控制 WAL 同步方法
SHOW wal_sync_method;
-- fdatasync (Linux 默认) — 只同步数据不更新元数据
-- open_datasync — write() 时使用 O_DSYNC
-- fsync — 同步数据和元数据
```

---

## 8. 数据安全保证总结

```
数据修改的持久化路径:

  INSERT/UPDATE/DELETE
     │
     ├─ 1. WAL Insert → WAL Buffer (共享内存)
     │      └─ 更新 Insert 位置
     │
     ├─ 2. [同步提交] XLogFlush → write() + fsync() → 磁盘
     │    [异步提交] 不等待，依赖 WAL Writer
     │
     ├─ 3. Commit 后: 更新 CLOG → CLOG 页面也受 WAL 规则保护
     │
     └─ 4. checkpointer: 刷脏页到磁盘 (确保 WAL 已先于页面刷盘)
            └─ FlushBuffer: XLogFlush(page_lsn) 然后 smgrwrite()
```

**崩溃恢复保证**：只要 Commit Record 的 WAL 已刷盘，崩溃后该事务的所有修改都能恢复。

**异步提交风险**：在主库崩溃时，最近 2 × wal_writer_delay (约 400ms) 内已通知客户端 "提交成功" 的事务可能丢失。

---

**关键源码文件**:
- `src/backend/access/transam/xlog.c` — `WalWriterMain`, `XLogFlush`, `XLogWrite`, `XLogCtlData`
- `src/backend/access/transam/xact.c` — `RecordTransactionCommit`
- `src/backend/storage/buffer/bufmgr.c` — `FlushBuffer` (WAL 先于数据规则)
- `src/backend/postmaster/walwriter.c` — WAL Writer 进程启动

**最后更新**: 2026-07 | **适用版本**: PostgreSQL 16.x
