# Lazy VACUUM

参考文档：

- [The Internals of PostgreSQL: 6 VACUUM Processing](https://www.interdb.jp/pg/pgsql06/index.html)

## 1. Overview

**Lazy vacuum**：在 `ShareUpdateExclusiveLock` 下按页清理堆与索引，不重写整表、不更换 `relfilenode`。普通 `VACUUM` 与 autovacuum worker 均走此路径。

| 路径          | 锁                         | 作用                                                                            | 文件                          |
| ------------- | -------------------------- | ------------------------------------------------------------------------------- | ----------------------------- |
| prune         | page cleanup lock          | 仅当前页；可回收 HOT 死版本；带索引项的死 lp 标 `LP_DEAD`                       | `pruneheap.c`                 |
| lazy `VACUUM` | `ShareUpdateExclusiveLock` | prune + 清理索引 + `LP_DEAD`→`LP_UNUSED` + 置 VM / 记 FSM；仅表尾连续空页可截断 | `vacuumlazy.c`                |
| `VACUUM FULL` | `AccessExclusiveLock`      | 按堆扫描顺序 `rewriteheap`，新 `relfilenode`，重建索引                          | `cluster.c` / `rewriteheap.c` |
| `CLUSTER tb`  | `AccessExclusiveLock`      | 按索引顺序 `rewriteheap`，新 `relfilenode`，重建索引                            | `cluster.c` / `rewriteheap.c` |

PG 9.0 起 `VACUUM FULL` 不再在原文件内搬元组，而是调用 `cluster_rel()`，与 `CLUSTER` 共用 `rewriteheap`：将仍需保留的元组写入新堆文件、重建全部索引、切换 `relfilenode` 后删除旧文件。

`VACUUM FULL` 和 `CLUSTER` 区别:

- `VACUUM FULL`：`vacuum_rel` 在 `VACOPT_FULL` 时调用 `cluster_rel`（不走 `heap_vacuum_rel`），按旧堆页顺序复制，不要求索引；目标是收缩膨胀。
- `CLUSTER tb` / `CLUSTER tb USING idx`：按指定索引（或 `pg_index.indisclustered` 记录的上次聚簇索引）顺序复制，使堆物理顺序接近该索引，Index Scan 更易顺序读盘；收缩是副作用。无可用索引时 `CLUSTER` 不能执行。

二者均持 `AccessExclusiveLock`，阻塞全部读写。见 [Lock Overview](../../storage/lmgr/01_overview.md)。

`ShareUpdateExclusiveLock` 与 `RowExclusiveLock` 不冲突，SELECT / INSERT / UPDATE / DELETE 可与 lazy `VACUUM` 并发；与另一 `VACUUM` 或 `CREATE INDEX CONCURRENTLY` 冲突。

---

## 2. Line Pointer

LP 的四种状态

```c
/*
 * lp_flags has these possible states.  An UNUSED line pointer is available
 * for immediate re-use, the other states are not.
 */
#define LP_UNUSED		0		/* unused (should always have lp_len=0) */
#define LP_NORMAL		1		/* used (should always have lp_len>0) */
#define LP_REDIRECT	    2		/* HOT redirect (should have lp_len=0) */
#define LP_DEAD			3		/* dead, may or may not have storage */
```

普通 / cold 旧版本: UNUSED → NORMAL [→ DEAD] → UNUSED
HOT 根（对外 TID）: UNUSED → NORMAL → REDIRECT [→ DEAD] → UNUSED
HOT 中间（HEAP_ONLY）: UNUSED → NORMAL → UNUSED

VACUUM 合法顺序：

1. 遍历 heap 标 `LP_DEAD`（保留编号、禁止复用；元组体可已由 prune 回收）：收集待清除的 tuple tid
2. 遍历 index 删除 1 收集的 tids 对应的索引项
3. heap 中 LP 改为 `LP_UNUSED` 允许 LP 复用

WHY: 为什么必须按照 `heap -> index -> heap` 的顺序处理，而不是直接处理 `index -> heap` 或者 `heap -> index`？

> 1. 如果 heap -> index 顺序直接清理 tuple 标记为 LP_UNUNSED，并发场景该 tuple 空间可能被复用，导致 index 指向非法数据
> 2. 如果 index -> heap 顺序首先清理 index 同时清理其对应的可能已经失效的 tuple，逐个回表检查是否 DEAD 处理效率太低

---

## 3. `OldestXmin`

VACUUM 不以当前会话快照为准，而要求元组对**所有仍可能引用它的快照**均不可见。

回收地平线由 ProcArray 计算：`ComputeXidHorizons` / `GetOldestXmin`（见 [transam README](../transam/00_readme.md)）：

- 已提交的 `xmax` **严格小于** `OldestXmin` → 可回收。
- 未结束事务、复制槽、预备事务会推迟该地平线，扫描后仍无法回收。

判定函数为 `HeapTupleSatisfiesVacuum`（`heapam_visibility.c`），而非查询路径的 `HeapTupleSatisfiesMVCC`。

```c
/* Result codes for HeapTupleSatisfiesVacuum */
typedef enum
{
	HEAPTUPLE_DEAD,				/* tuple is dead and deletable */
	HEAPTUPLE_LIVE,				/* tuple is live (committed, no deleter) */
	HEAPTUPLE_RECENTLY_DEAD,	/* tuple is dead, but not deletable yet */
	HEAPTUPLE_INSERT_IN_PROGRESS,	/* inserting xact is still in progress */
	HEAPTUPLE_DELETE_IN_PROGRESS	/* deleting xact is still in progress */
} HTSV_Result;
```

---

## 4. Call Stack

```c
ExecVacuum | vacuum /* vacuum relations or all releated tables */
    vacuum_rel
        /* or cluster_rel for vacuum full */
        table_relation_vacuum | heap_vacuum_rel /* perform VACUUM for one heap relation */
            lazy_scan_heap      /* heap pruning + index vac + heap vac */
                lazy_scan_prune /* prune heap pages */
                    heap_page_prune /* prune one page */
                        heap_prune_satisfies_vacuum /* tuple visibility checks */
                        heap_prune_chain /* process all line pointer */
                        heap_page_prune_execute
                            ItemIdSetRedirect /* Update all redirected line pointers */
	        	            ItemIdSetDead     /* Update all now-dead line pointers */
	        	            ItemIdSetUnused   /* Update all now-unused line pointers */
	        	            PageRepairFragmentation
	        		            compactify_tuples
                        PageClearFull
                        MarkBufferDirty
                        XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_PRUNE)
                    heap_prepare_freeze_tuple
                    heap_freeze_execute_prepared /* freeze heap tuples */
                        heap_execute_freeze_tuple /* Execute the prepared freezing of a tuple with caller's freeze plan */
                        MarkBufferDirty
                        XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_FREEZE_PAGE);
                lazy_vacuum     /* index vacuuming */
                    lazy_vacuum_all_indexes
                        lazy_vacuum_one_index | vac_bulkdel_one_index /* vacuum index relation */
                            index_bulk_delete | IndexAmRoutine::ambulkdelete
                                btbulkdelete /* nbtree.c */
                    lazy_vacuum_heap_rel /* LP_DEAD -> LP_UNUSED */
                        lazy_vacuum_heap_page
                            ItemIdSetUnused
                            PageTruncateLinePointerArray
                            MarkBufferDirty
                            XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_VACUUM);
            lazy_truncate_heap
            vac_update_relstats /* update stats */
    vac_update_datfrozenxid
```

`lazy_scan_heap`

> 按块号扫描堆。VM 已标记 **all-visible** 的页，普通 vacuum **跳过**（无待回收 dead tuple）。以 freeze 为目的的 aggressive 扫描除外。

1. 获取 cleanup lock（与普通读 pin 互斥；失败则等待或稍后重试）。
2. `heap_page_prune`：回收 HOT 死版本；将仍被索引引用的死元组标为 `LP_DEAD`（槽保留，`lp_off` 无意义）。
3. 将本页全部 `LP_DEAD` 的 `(blk, offset)` 记入死 TID 集合。
4. 若页内已无 dead 且对所有快照可见 → 置 `PD_ALL_VISIBLE` 并 `visibilitymap_set`（WAL：`log_heap_visible`）。见 [VM](./01_vm.md)。
5. `RecordPageWithFreeSpace` 更新 [FSM](../../storage/freespace/01_fsm.md)。

`lazy_vacuum_all_indexes`

- 对每个索引调用 `ambulkdelete`（nbtree 扫描叶页，删除 `ctid ∈ 死 TID 集` 的项）。无索引或本轮无死 TID 则跳过。

`lazy_vacuum_heap_rel`

- 再次访问含死 TID 的堆页，将对应 `LP_DEAD` 改为 `LP_UNUSED`。
- 此后 `INSERT` 可复用该 OffsetNumber（优先占用空槽，而非扩展 `pd_lower`）。

> cold update 见 [update trace](../../../traces/03_update.md)：索引中 `(0,1)` 删除之后，lp 1 才可改为 `LP_UNUSED`。HOT 在 vacuum 后常见 `LP_REDIRECT`，索引仍指向 root。

收尾

- `lazy_cleanup_all_indexes`：`ambulkvacuumcleanup`（b-tree 回收空页、更新 `reltuples`）。
- `lazy_truncate_heap`：表尾连续空页时缩小文件；并发扫描可能导致截断放弃。文件中部空洞不会消失。
- `vac_update_relstats`：写入 `pg_class` / `pgstat`。

---

**cold UPDATE / DELETE**：索引有两条 entry（旧、新各一条）。

```
committed, not yet vacuumed
    Index --> lp[1] LP_NORMAL   /* old; xmax committed */
    Index --> lp[2] LP_NORMAL   /* new row, second index entry */

heap_page_prune（indexes not vacuumed yet）
    Index --> lp[1] LP_DEAD     /* slot kept; body may be gone */
    Index --> lp[2] LP_NORMAL

lazy_vacuum_heap_rel（after index dead-TID cleanup）
              lp[1] LP_UNUSED     /* slot reusable for INSERT */
    Index --> lp[2] LP_NORMAL
```

**HOT UPDATE**：索引仅一条 entry，指向 root。

```
committed, not yet vacuumed
    Index --> lp[1] LP_NORMAL   /* root; HOT_UPDATED chain */
              lp[2] LP_NORMAL   /* HEAP_ONLY live version; no index entry */

heap_page_prune（same lazy_scan_heap pass）
    Index --> lp[1] LP_REDIRECT --> lp[2] LP_NORMAL
              /* index still (blk,1); root shortened, no index vacuum needed */
```

---

## 6. Lock

| 对象   | 锁                         | 作用                                           |
| ------ | -------------------------- | ---------------------------------------------- |
| 表     | `ShareUpdateExclusiveLock` | 排斥第二个 VACUUM / 部分 DDL；允许 DML         |
| 堆页   | cleanup lock               | prune、修改 lp、置 `PD_ALL_VISIBLE` 时独占该页 |
| 索引页 | 各 AM 的 vacuum 锁         | 删除死索引项                                   |

- DML 与 vacuum 并发时，本轮只回收扫描时已满足条件的死元组；此后产生的死元组留待下一轮
- 置 VM 须持有堆页锁并复核，避免刚标记 all-visible 即被 INSERT 修改

> - `vacuum_cost_delay` / `vacuum_cost_limit`：按读页、写页、命中脏页累计费用，超过限额则 `sleep`。autovacuum 使用独立的 cost 参数。
> - PG 11+ 可对索引 vacuum 启动并行 worker（`min_parallel_index_scan_size` 等）；堆扫描仍由 leader 执行。

---

## 7. Case

关闭表级 autovacuum，避免 worker 在观测前完成 prune / vacuum。

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;

DROP TABLE IF EXISTS tb;
CREATE TABLE tb (a int PRIMARY KEY, b int) WITH (autovacuum_enabled = off);

-- three kinds of dead tuples in one page
INSERT INTO tb VALUES (1, 10), (2, 20), (3, 30);
DELETE FROM tb WHERE a = 1;        -- (1) plain delete
UPDATE tb SET a = 22 WHERE a = 2;  -- (2) cold update: indexed column changed
UPDATE tb SET b = 33 WHERE a = 3;  -- (3) hot update: non-indexed column only

-- before VACUUM: lp 1-3 dead, lp 4-5 live
SELECT lp, lp_flags, t_xmin, t_xmax, t_ctid
FROM heap_page_items(get_raw_page('tb', 0));

-- 4 entries: a=1,2,3,22
SELECT itemoffset, ctid FROM bt_page_items('tb_pkey', 1);

VACUUM FREEZE VERBOSE tb;

-- after VACUUM: changes on lp 1-3
SELECT lp, lp_off, lp_flags
FROM heap_page_items(get_raw_page('tb', 0));

-- only a=3, a=22 remain
SELECT itemoffset, ctid FROM bt_page_items('tb_pkey', 1);
```

> HOT：仅修改 `b` 时无需新索引项，prune 后 root lp 变为 `LP_REDIRECT` 指向活版本；仅当整条 HOT 链都死时，root 才随索引清理变为 `LP_UNUSED`。
> `VACUUM VERBOSE tb;` 输出扫描页数、跳过的 all-visible 页、回收行数及各索引删除项数。

---

## 9. Summary

1. Lazy vacuum 与 DML 并发。扫堆阶段完成 prune、置 VM、更新 FSM，并收集死 TID；随后两遍清理：先索引（`ambulkdelete`）→ 再回访堆页把 `LP_DEAD` 改 `LP_UNUSED`。死 TID 过多时按 `maintenance_work_mem` 分批多轮。
2. prune 不掌握索引信息：非 `HEAP_ONLY` 的死元组最多标到 `LP_DEAD`，槽复用必须等索引清理；HOT 中间版本无索引项，prune 可直接页内回收。root 仍被索引引用，整链死时同样等索引清理。
3. 不更换文件、不消除中部空洞；截断仅发生在表尾连续空页。整表缩小走 `rewriteheap`：`VACUUM FULL`（堆序）或 `CLUSTER`（索引序）。
4. 无法回收通常是 `OldestXmin` 被长事务或复制槽推迟，而非 VACUUM 未执行。

---

**相关笔记**: [Heap AM](./heap.md) · [Page Prune](./03_prune.md) · [HOT](./02_hot.md) · [VM](./01_vm.md) · [FSM](../../storage/freespace/01_fsm.md) · [MVCC Visibility](../transam/08_mvcc_visibility.md) · [Lock Overview](../../storage/lmgr/01_overview.md) · [trace: delete](../../../traces/02_delete.md) · [trace: update](../../../traces/03_update.md)
