# WAL 概述

## 什么是 WAL

WAL (Write-Ahead Logging) 是 PostgreSQL 实现崩溃恢复、时间点恢复 (PITR) 和流复制的核心机制。规则很简单：**在对数据页面做任何修改之前，必须先将描述该修改的日志记录写入稳定存储 (磁盘)**。

```
修改顺序:
  ① 写 WAL 记录到 WAL Buffer
  ② 必要时将 WAL Flush 到磁盘
  ③ 修改数据页面 (shared buffer)
  ④ 标记 buffer 为脏

恢复重放:
  ① 读取 WAL 记录
  ② 检查页面 LSN >= WAL 记录 LSN → 已应用，跳过
  ③ 否则：如果是 FPW → 恢复完整页面；否则 → 重做增量修改
```

## 核心数据结构概览

| 数据结构 | 位置 | 作用 |
|---------|------|------|
| `XLogRecPtr` (LSN) | `xlogrecord.h` | 64 位 WAL 位置指针，唯一标识一条 WAL 记录 |
| `XLogRecord` | `xlogrecord.h` | WAL 记录的物理头部 |
| `XLogRecData` | `xloginsert.h` | 零拷贝链表节点，指向要写入的原始数据 |
| `registered_buffer` | `xloginsert.c` | 注册的被修改页面信息 (block_id, flags, buf data 链表) |
| `XLogCtlData` | `xlog.c` | WAL 共享内存控制结构 (WAL Buffer、Insert 位置、Flush 位置等) |
| `WALInsertLocks` | `xlog.c` | 多后端并发插入锁 (NUM_XLOGINSERT_LOCKS = 8) |
| `XLogPageHeaderData` | `xlog_internal.h` | WAL 段文件内每页的头部 |

## 源码文件地图

```
src/include/access/
  xlogrecord.h          — XLogRecord, XLogRecPtr, 块引用结构定义
  xloginsert.h          — XLogRecData, XLogBeginInsert/XLogRegister*/XLogInsert API
  xlog_internal.h       — WAL 段文件格式、LSN 宏、内部常量
  xlog.h                — XLogFlush, XLogBackgroundFlush, checkpoint 等高层 API
  xlogreader.h          — WAL 记录解码器 (XLogReaderState)
  xlogdefs.h            — WAL 相关基本类型定义
  rmgr.h                — Resource Manager 注册
  rmgrlist.h            — 所有 RMgr 列表 (XLOG, Transaction, Heap, Btree 等)

src/backend/access/transam/
  xlog.c                — WAL 主控：初始化、checkpoint、WAL 写入、恢复入口
  xloginsert.c          — WAL 记录构造与插入 (XLogInsert, XLogRecordAssemble)
  xlogreader.c          — WAL 记录解码/读取
  xlogrecovery.c        — 崩溃恢复逻辑 (Startup 进程)
  xlogarchive.c         — WAL 归档 (archive_command)
  xlogfuncs.c           — pg_wal_* SQL 函数
  xlogutils.c           — 恢复期间的辅助工具
```

## WAL 的角色矩阵

| 角色 | 说明 | 依赖 |
|------|------|------|
| **崩溃恢复 (Crash Recovery)** | 实例崩溃后，重放未刷盘的 WAL，恢复到一致状态 | LSN 比较 |
| **时间点恢复 (PITR)** | 利用归档 WAL + 基础备份，恢复到任意时间点 | WAL 归档 |
| **流复制 (Streaming Replication)** | 主库将 WAL 实时发送给备库，实现高可用 | WAL Sender |
| **逻辑复制 (Logical Replication)** | 解码 WAL 为逻辑变更，订阅端重放 | Logical Decoding |
| **热备查询 (Hot Standby)** | 备库在恢复期间允许只读查询 | Recovery Conflict |
| **全页保护 (FPW)** | 防止撕裂页，检查点后首次修改记录完整页面镜像 | Full Page Writes |

## WAL 设计原则 (摘自 transam README)

1. **日志先于数据**：bufmgr 在写出脏页之前，必须确保 WAL 至少已刷到该页的 LSN。
2. **LSN 检查**：重放时比较页面 LSN 与日志记录的 WAL 位置，避免重复应用。
3. **全页镜像**：检查点后对某页的首次修改包含完整页面副本，防止撕裂页。
4. **CRC 校验**：WAL 记录包含 CRC，可以验证其有效性。
5. **原子 WAL 记录**：复杂操作 (如 B-tree split) 分解为多个原子 WAL 记录，中间状态必须自洽。
6. **临界区保护**：修改 buffer 和写入 WAL 必须包裹在 `START_CRIT_SECTION` / `END_CRIT_SECTION` 之间。

## WAL 操作通用模式

```c
// 1. Pin 并独占锁定要修改的 buffer
buffer = ReadBuffer(rel, block);
LockBuffer(buffer, BUFFER_LOCK_EXCLUSIVE);

// 2. 进入临界区（任何错误导致 PANIC）
START_CRIT_SECTION();

// 3. 修改 buffer
PageAddItem(page, item, ...);

// 4. 标记 buffer 为脏
MarkBufferDirty(buffer);  // 必须在写 WAL 之前

// 5. 构造并插入 WAL 记录
XLogBeginInsert();
XLogRegisterBuffer(0, buffer, REGBUF_STANDARD);
XLogRegisterData(&xlrec, sizeof(xlrec));
XLogRegisterBufData(0, data, len);
recptr = XLogInsert(RM_FOO_ID, XLOG_FOO_INSERT);
PageSetLSN(page, recptr);

// 6. 退出临界区
END_CRIT_SECTION();

// 7. 解锁并 Unpin
UnlockReleaseBuffer(buffer);
```

关键顺序：`MarkBufferDirty` 必须在写 WAL 之前；`PageSetLSN` 必须在 `XLogInsert` 之后；整个过程必须在临界区内。

## 与其他模块的关系

```
                    ┌──────────────┐
                    │   Executor   │
                    └──────┬───────┘
                           │ (insert/update/delete)
                    ┌──────▼───────┐
                    │  Access Mgr  │ (heap_insert, btree_insert, ...)
                    └──────┬───────┘
                           │ XLogBeginInsert / XLogRegister* / XLogInsert
                    ┌──────▼───────┐
                    │  WAL Layer   │ ← 本模块
                    └──┬───────┬───┘
                       │       │
              ┌────────▼─┐  ┌──▼───────────┐
              │ Buffer Mgr│  │ WAL File I/O │
              └──────────┘  └──────────────┘
                (MarkBufferDirty)

              ┌──────────────┐
              │  Checkpointer│ ← 触发 WAL 切换 + checkpoint LSN
              └──────────────┘
              ┌──────────────┐
              │  WAL Writer  │ ← 后台刷 WAL 到磁盘
              └──────────────┘
              ┌──────────────┐
              │  WAL Sender  │ ← 流复制: 发送 WAL 给备库
              └──────────────┘
```

## 关键源码阅读入口

| 入口 | 文件 | 说明 |
|------|------|------|
| WAL 插入 API | `xloginsert.h:64-115` | XLogBeginInsert, XLogRegisterBuffer, XLogRegisterData, XLogRegisterBufData, XLogInsert |
| WAL 记录格式 | `xlogrecord.h:80-150` | XLogRecord 结构体，BkpBlock，XLogRecPtr |
| WAL 组装 | `xloginsert.c:565` | XLogRecordAssemble — 注册数据链表的最终组装 |
| WAL 写入 | `xlog.c:1500` | XLogInsertRecord — 将组装好的记录复制到 WAL Buffer |
| WAL 刷新 | `xlog.c:2600` | XLogFlush — 将 WAL Buffer 刷到磁盘至指定 LSN |
| WAL 段文件格式 | `xlog_internal.h:50-120` | XLogPageHeaderData、XLogLongPageHeaderData |
| 恢复入口 | `xlogrecovery.c` | StartupXLOG — 崩溃恢复主循环 |
| WAL Writer | `xlog.c:6400` | WalWriterMain — 后台 WAL Writer 进程主循环 |

## 学习路线

遵循本模块的阅读顺序 (00 → 01 → 02 → 03 → 04 → 05)：

| 序号 | 主题 | 解决的问题 |
|------|------|-----------|
| 01 | WAL 结构与 LSN | WAL 记录长什么样？LSN 是什么？WAL 文件如何组织？ |
| 02 | WAL 记录插入 | 一条 WAL 记录是如何产生并写入 WAL Buffer 的？ |
| 03 | Mini-Transaction | WAL 如何与 buffer 修改组成原子操作？ |
| 04 | Full Page Writes | 为什么需要完整页面镜像？什么时候触发？ |
| 05 | WAL Writer & Flush | WAL 如何从内存 (WAL Buffer) 安全地持久化到磁盘？ |
