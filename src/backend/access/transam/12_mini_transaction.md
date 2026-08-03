# What & Why: Mini-Transaction

## 1. What is MTR

- MTR: Mini-Transaction, 是比 SQL 事务更小的物理原子单元：改共享缓冲、写入一条 WAL、再更新相关页的 `pd_lsn`。崩溃恢复时，这条 WAL 对应的改动要么整段生效，要么整段不生效。
- 实现: **atomic action**。一条 WAL 记录 = 一次可 redo 的原子动作`START_CRIT_SECTION` / `END_CRIT_SECTION` 包住改页与记 WAL

> nbtree README：`A single WAL entry is effectively an atomic action`

- 用户事务（top-level，`BEGIN…COMMIT`）：逻辑原子边界；靠 top XID / CLOG / 可见性回答「整笔是否已提交」
- 子事务（SAVEPOINT / 内部 subxact）：嵌在用户事务里的逻辑子边界；可有自己的 XID，但最终仍随祖先提交或回滚；回答「这段逻辑改动在父事务内是否保留」
- MTR（atomic action）：物理原子边界；一条 WAL（可多页）回答「这条记录覆盖的页改动在 redo 时是否一体」

> 一次用户事务（及其子事务）里通常有许多条 MTR；子事务回滚只改逻辑可见性，不撤销「已写出的 WAL 物理原子性」。

---

## 2. 核心设计思想

Redo 的原子边界 = **一条 WAL 记录**。

判定标准：哪些页改动若只应用一半，读者/后续插入会看到**结构上不可搜索或不可修复**的状态？这些必须同记一条。

以 B-tree split 为例，**一条 `XLOG_BTREE_SPLIT` 至少要盖住本层一体**：

- 左页（收缩、high key、`INCOMPLETE_SPLIT` …）
- 右页（新页 + 挪过去的元组）
- 原右兄弟的 left-link（若有）

**可以不在这一条里**：往父页插 downlink（下一条 WAL）。两步之间允许「缺 downlink」，但靠 flag + 后续插入可补完，搜索仍可用。

配套约束：这些改动包在同一临界区里写 WAL；半路 ERROR→PANIC，避免「缓冲已脏、WAL 未记」。

---

## 3. 关键文件与 API

| 概念            | 源码 / 文档                                                                                         |
| --------------- | --------------------------------------------------------------------------------------------------- |
| 临界区          | `src/include/miscadmin.h` — `START_CRIT_SECTION` / `END_CRIT_SECTION`                               |
| 改页标准序      | `src/backend/access/transam/README`（预写日志编码）；`heap_insert` / `heap_update`                  |
| 多页注册        | `src/backend/access/transam/xloginsert.c` — `XLogBeginInsert` / `XLogRegisterBuffer` / `XLogInsert` |
| B-tree 原子动作 | `src/backend/access/nbtree/README`（WAL / incomplete split）；`nbtxlog.c` / `_bt_split`             |

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

## 4. 与用户事务的分层

### 4.1 两层原子性

| 层                  | 粒度                     | 保证                                       |
| ------------------- | ------------------------ | ------------------------------------------ |
| 用户事务            | `BEGIN…COMMIT`           | 多语句逻辑原子；靠 top XID / CLOG / 可见性 |
| 子事务              | SAVEPOINT / 内部 subxact | 父事务内的逻辑子边界；提交仍取决于祖先     |
| MTR / atomic action | 一条 WAL（可多页）       | 崩溃后 redo 时，该记录覆盖的物理状态自洽   |

COMMIT 之前崩溃：事务逻辑上未提交，但已写入的 WAL 仍会 redo；页上物理修改可以留下，靠 MVCC 对未提交 XID 不可见。

MTR 约束的是另一类不变式：同一条 redo 记录涉及的多页，不能只应用一半。

### 4.2 单页与多页

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

注册形态（buffer 列表可再含兄弟页；BufData / MainData 见 [WAL Record Structure & Insertion](./10_wal_record_insert.md)）：

```c
XLogBeginInsert();
XLogRegisterBuffer(0, leftbuf, REGBUF_STANDARD);
XLogRegisterBuffer(1, rightbuf, REGBUF_STANDARD);
/* sibling buffers, BufData / MainData ... */
XLogInsert(RM_BTREE_ID, XLOG_BTREE_SPLIT);
```

nbtree README：分裂由多个 atomic action 组成。两步之间崩溃会缺 downlink；靠 `INCOMPLETE_SPLIT` 与后续插入补完，搜索仍可用。

WAL redo 的原子边界是记录，不是 SQL 事务。必须同进同退的多页物理不变式，收进同一条 WAL，并包在同一临界区里。

### 4.3 与 FPW / LSN

- FPW：防单页半写。MTR 里注册的每个 buffer 仍按 `page_lsn <= RedoRecPtr` 决定是否拍 FPI（[Full Page Writes](./13_full_page_writes.md)）。
- LSN：`XLogInsert` 返回的 EndRecPtr 写到本条记录改过的每一页的 `pd_lsn`；redo 用 `lsn <= PageGetLSN` 判断该页是否已含本 atomic action（[XLogRecPtr (LSN)](./11_xlogrecptr_lsn.md)）。

职责划分：MTR 决定「哪些页挂在同一条 WAL」；FPW / LSN 决定「如何防半写、如何判断该记录是否已应用到某页」。

---

## 5. 跨多条 WAL 的中间状态

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

1. 正常运行时，子页写锁跨过 MTR-1→MTR-2，挡住的是**第二个插入者/writer**（防其重复补完分裂）；读者本就忽略该 flag，靠右移穿过。
2. 崩溃后可能看到 incomplete；算法必须可处理（lazy finish，不在 end-of-recovery 强行补完）。
3. Hot Standby 重放时，每条 WAL 独立回放：**跨层**锁耦合不重建（读者不关心 incomplete flag），但**同层**锁仍按主库方式持有，避免读者看到同层不一致。

---

## 6. 速查

| 问题                                   | 答案                                                                        |
| -------------------------------------- | --------------------------------------------------------------------------- |
| MTR 是用户事务的子集吗？               | 不是同一层；是物理 WAL 原子单元                                             |
| 原子边界是什么？                       | 一条 WAL 记录（可含多 block）                                               |
| 为何 critical section 内 ERROR→PANIC？ | 改页与记 WAL 之间失败会留下未记录脏页；ERROR 清不掉共享缓冲                 |
| 单页 heap insert 算 MTR 吗？           | 算；最简单形态                                                              |
| B-tree split 几个 MTR？                | 本层 split 一条；父级 downlink（及可能的上层 split）另算                    |
| 与 InnoDB MTR？                        | 「Mini-Transaction」是借用 InnoDB/ARIES 叫法；PG 源码几乎只用 atomic action |

---

## 7. 总结

1. What：MTR = 临界区包住的「改（多）页 + 一条 WAL + 统一 `PageSetLSN`」；源码称 atomic action。
2. Why：崩溃恢复按 WAL 记录 redo；多页不变式必须同记一条，否则半分裂。
3. 边界：整事务可拆成多条 MTR；中间态须对搜索/插入可修复（incomplete split）。
4. 范围外：`_bt_split` / `XLOG_BTREE_SPLIT` 的逐页字段与实验对照，放在 nbtree 写路径笔记。

---

**相关笔记**: [XLogRecPtr (LSN)](./11_xlogrecptr_lsn.md) · [Full Page Writes](./13_full_page_writes.md) · [WAL Record Structure & Insertion](./10_wal_record_insert.md) · [nbtree README](../nbtree/00_readme.md) · [insert 链路](../../../traces/01_insert.md)

**最后更新**: 2026-07-20 | **适用版本**: PostgreSQL 15.x / 16.x / devel
