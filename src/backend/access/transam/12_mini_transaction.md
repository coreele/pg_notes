# What & Why: Mini-Transaction

## What is MTR

Mini-Transaction（MTR）是比 SQL 事务更小的物理原子单元：改共享缓冲、写入一条 WAL、再更新相关页的 `pd_lsn`。崩溃恢复时，这条 WAL 对应的改动要么整段生效，要么整段不生效。

源码侧更常叫 atomic action（nbtree README：`A single WAL entry is effectively an atomic action`）。MTR 是同一概念的习惯叫法；本笔记两者同指「一条完整的 WAL 记录」。

| 说法 | 落点 |
|------|------|
| atomic action | 一条 WAL 记录 = 一次可 redo 的原子动作 |
| critical section | `START_CRIT_SECTION` / `END_CRIT_SECTION` 包住改页与记 WAL |
| 多页注册 | 同一条记录里 `XLogRegisterBuffer(0..n)` |

分层：用户事务回答「逻辑上是否已提交」；MTR 回答「这条 WAL 所覆盖的物理改动在 redo 时是否一体」。

---

## 核心设计思想

- 问题：一次逻辑操作常改多页（B-tree split：左页、右页、兄弟 left-link；再往上插 downlink）。若每页各自一条 WAL、中间可崩溃，磁盘上可能留下半棵树。
- 解法：必须同进同退的多页改动收进同一条 WAL；临界区内 ERROR 升级为 PANIC，避免共享缓冲已脏但 WAL 未记上。
- 边界：整棵树 / 整条 SQL 事务不必一条 WAL 做完。中间状态必须对读者可搜索（incomplete split 用 flag，由后续插入补完）。

---

## 1. 关键文件与 API

| 概念 | 源码 / 文档 |
|------|-------------|
| 临界区 | `src/include/miscadmin.h` — `START_CRIT_SECTION` / `END_CRIT_SECTION` |
| 改页标准序 | `src/backend/access/transam/README`（预写日志编码）；`heap_insert` / `heap_update` |
| 多页注册 | `src/backend/access/transam/xloginsert.c` — `XLogBeginInsert` / `XLogRegisterBuffer` / `XLogInsert` |
| B-tree 原子动作 | `src/backend/access/nbtree/README`（WAL / incomplete split）；`nbtxlog.c` / `_bt_split` |

标准骨架（与 INSERT / UPDATE trace 一致）：

```text
pin + exclusive lock page(s)
  -> (outside crit: space checks etc.; ERROR ok)
START_CRIT_SECTION()
  -> modify shared buffers
  -> MarkBufferDirty
  -> XLogBeginInsert / Register* / XLogInsert
  -> PageSetLSN(each touched page, EndRecPtr)
END_CRIT_SECTION()
unlock / unpin
```

临界区内出错会 PANIC：共享缓冲已有未记 WAL 的修改，不能让这类脏页刷盘。空间是否足够等检查必须放在 `START_CRIT_SECTION` 之前。

危险窗口：已改页并 `MarkBufferDirty`，但 `XLogInsert` 尚未成功。此时页上 `pd_lsn` 往往仍是旧值；若仅 ERROR 回滚而后端继续运行，bgwriter 可能按旧 LSN 刷脏，把未进 WAL 的内容写入数据文件，恢复时又因页 LSN 够新而跳过 redo。PANIC 丢掉共享内存并走 crash recovery，避免这种静默损坏。

---

## 2. 与用户事务的分层

### 2.1 两层原子性

| 层 | 粒度 | 保证 |
|----|------|------|
| 用户事务 | BEGIN…COMMIT | 多语句逻辑原子；靠 XID / CLOG / 可见性 |
| MTR / atomic action | 一条 WAL（可多页） | 崩溃后 redo 时，该记录覆盖的物理状态自洽 |

COMMIT 之前崩溃：事务逻辑上未提交，但已写入的 WAL 仍会 redo；页上物理修改可以留下，靠 MVCC 对未提交 XID 不可见。

MTR 约束的是另一类不变式：同一条 redo 记录涉及的多页，不能只应用一半。

### 2.2 单页与多页

普通 heap insert：一页 + 一条 `XLOG_HEAP_INSERT`，本身就是一个 MTR。

B-tree 页分裂时，一条 `XLOG_BTREE_SPLIT` 覆盖本层必须一体的改动；父页 downlink 另写一条 WAL：

```text
XLOG_BTREE_SPLIT (one atomic action)
  left page   (shrink, high key, INCOMPLETE_SPLIT, ...)
  right page  (new page + moved tuples)
  old right sibling left-link (if any)

next WAL record: insert downlink in parent
  (may itself split and emit more records)
```

注册形态（buffer 列表可再含兄弟页；BufData / MainData 见 WAL Record 笔记）：

```c
XLogBeginInsert();
XLogRegisterBuffer(0, leftbuf, REGBUF_STANDARD);
XLogRegisterBuffer(1, rightbuf, REGBUF_STANDARD);
/* sibling buffers, BufData / MainData ... */
XLogInsert(RM_BTREE_ID, XLOG_BTREE_SPLIT);
```

nbtree README：分裂由多个 atomic action 组成。两步之间崩溃会缺 downlink；靠 `INCOMPLETE_SPLIT` 与后续插入补完，搜索仍可用。

WAL redo 的原子边界是记录，不是 SQL 事务。必须同进同退的多页物理不变式，收进同一条 WAL，并包在同一临界区里。

### 2.3 与 FPW / LSN

- FPW：防单页半写。MTR 里注册的每个 buffer 仍按 `page_lsn <= RedoRecPtr` 决定是否拍 FPI（[Full Page Writes](./10_full_page_writes.md)）。
- LSN：`XLogInsert` 返回的 EndRecPtr 写到本条记录改过的每一页的 `pd_lsn`；redo 用 `lsn <= PageGetLSN` 判断该页是否已含本 atomic action（[XLogRecPtr (LSN)](./11_xlogrecptr_lsn.md)）。

职责划分：MTR 决定「哪些页挂在同一条 WAL」；FPW / LSN 决定「如何防半写、如何判断该记录是否已应用到某页」。

---

## 3. 跨多条 WAL 的中间状态

多级索引插入拆成一串 MTR；每条结束后树必须可搜索：

```text
MTR-1: leaf split
       (downlink may be missing; left page has INCOMPLETE_SPLIT)
       crash A: readers follow right-link;
                inserters finish split when flag seen
MTR-2: insert downlink in parent; clear incomplete flag
       crash B: structure complete
(parent full -> more MTRs up the tree)
```

约束（`transam/README` / nbtree README）：

1. 正常运行时，子页锁跨过 MTR-1→MTR-2，其他后端看不到 incomplete。
2. 崩溃后可能看到 incomplete；算法必须可处理（lazy finish，不在 end-of-recovery 强行补完）。
3. Hot Standby 重放时，每条 WAL 独立回放，且各自留下对读者一致的状态。

---

## 4. 速查

| 问题 | 答案 |
|------|------|
| MTR 是用户事务的子集吗？ | 不是同一层；是物理 WAL 原子单元 |
| 原子边界是什么？ | 一条 WAL 记录（可含多 block） |
| 为何 critical section 内 ERROR→PANIC？ | 改页与记 WAL 之间失败会留下未记录脏页；ERROR 清不掉共享缓冲 |
| 单页 heap insert 算 MTR 吗？ | 算；最简单形态 |
| B-tree split 几个 MTR？ | 本层 split 一条；父级 downlink（及可能的上层 split）另算 |
| 与 InnoDB MTR？ | 概念接近；PG 术语偏 atomic action |

---

## 5. 总结

1. What：MTR = 临界区包住的「改（多）页 + 一条 WAL + 统一 `PageSetLSN`」；源码称 atomic action。
2. Why：崩溃恢复按 WAL 记录 redo；多页不变式必须同记一条，否则半分裂。
3. 边界：整事务可拆成多条 MTR；中间态须对搜索/插入可修复（incomplete split）。
4. 范围外：`_bt_split` / `XLOG_BTREE_SPLIT` 的逐页字段与实验对照，放在 nbtree 写路径笔记。

---

**相关笔记**: [XLogRecPtr (LSN)](./11_xlogrecptr_lsn.md) · [Full Page Writes](./10_full_page_writes.md) · [WAL Record](../../../../temp/wal_record.md) · [nbtree README](../nbtree/00_readme.md) · [insert 链路](../../../traces/01_insert.md)

**最后更新**: 2026-07-20 | **适用版本**: PostgreSQL 15.x / 16.x / devel
