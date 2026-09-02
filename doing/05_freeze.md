# Freeze（元组冻结）

## 1. 定义

**Freeze**：把存活元组中**老于冻结视界**的 XID / MultiXactId 从可见性判定中抹除，使元组对所有当前与未来快照**永远视为「过去」**，从而推进 `relfrozenxid`、防止 XID 回卷（wraparound），并让 `pg_xact`（clog）得以截断回收。**不删元组、不改数据内容，只改写 tuple 头的 xmin/xmax/xvac 与 infomask。**

freeze 没有独立入口，作为 lazy `VACUUM` 扫页的一部分在 `lazy_scan_prune()` 中执行。对照：[Page Prune](../src/backend/access/heap/03_prune.md) · [Lazy VACUUM](../src/backend/access/heap/04_vacuumlazy.md) · [VM](../src/backend/access/heap/01_vm.md)。

源码：判定与执行在 `access/heap/heapam.c`（PG 17 起拆出 `heapfreeze.c`），VACUUM 集成在 `vacuumlazy.c`，cutoff 计算在 `commands/vacuum.c` 的 `vacuum_get_cutoffs()`。

| 路径                       | 入口                                    | 特点                                               |
| -------------------------- | --------------------------------------- | -------------------------------------------------- |
| 普通 VACUUM / autovacuum   | `lazy_scan_prune()`                     | XID < `FreezeLimit` 时必须冻；否则 VACUUM 自主决定 |
| anti-wraparound autovacuum | 同上（`is_wraparound` → aggressive）    | `relfrozenxid` 过老时自动发起，绕过阈值缩放        |
| `VACUUM FREEZE`            | 同上（四个 freeze age 全部置 0）        | 尽量全冻                                           |
| `CLUSTER` / `VACUUM FULL`  | `rewriteheap.c` → `heap_freeze_tuple()` | 重写新堆时顺手冻结；不写单条 WAL，随整体重写落盘   |
| WAL replay                 | `heap_xlog_freeze_page()`               | 应用 `XLOG_HEAP2_FREEZE_PAGE`                      |

---

## 2. 为何需要：32-bit XID 回卷

XID 是 32 位环形整数，比较语义为模 2³² 的有符号差：`TransactionIdPrecedes(a,b) ≡ (int32)(a-b) < 0`。「过去」与「未来」各占 2³¹。若放任某元组的 `xmin` 与当前 `nextXID` 的距离逼近 2³¹，这个老元组会被误判为「未来」事务插入 → 突然不可见，**数据凭空消失**。

对策：在距离 2³¹ 还有充足余量时冻结老元组。冻结带来三件事：

1. **可见性**：`HEAP_XMIN_FROZEN` 使任何快照无需查 clog 直接判可见；
2. **推进 `relfrozenxid`**：`pg_class.relfrozenxid` 语义为「表中所有 XID < relfrozenxid 的元组都已被冻结（或不存在）」，它给出表内仍需查 clog 的 XID 下界；
3. **clog 截断**：全库最老的 `datfrozenxid` 之前的 `pg_xact` 段可删（`vac_truncate_clog`，见 [CLOG](../src/backend/access/transam/09_clog.md)）。

`xmax`、MultiXactId 同理：未冻结的 lock/update 痕迹同样会拖住 `relfrozenxid` / `relminmxid`，所以 freeze 必须连同 `xmax`（含 multi 成员）一起处理。

---

## 3. Frozen 长什么样：infomask 标记，不改写 xmin

```c
#define HEAP_XMIN_COMMITTED 0x0100
#define HEAP_XMIN_INVALID   0x0200
#define HEAP_XMIN_FROZEN    (HEAP_XMIN_COMMITTED | HEAP_XMIN_INVALID)  /* 0x0300 */
```

- PG 9.4 起 freeze **不再把 xmin 改写成** `FrozenTransactionId`（2），只置 `HEAP_XMIN_FROZEN` 位，原始 xmin 保留（对调试、pg_upgrade 有价值）；
- `HeapTupleHeaderGetXmin()` 对 frozen tuple 返回 `FrozenTransactionId`（`htup_details.h`），可见性代码对外透明；
- 只有 `xvac` 字段（9.0 以前老式 `VACUUM FULL` 的 `HEAP_MOVED_OFF/IN` 遗留）仍会真的写入 2 / Invalid——今天几乎见不到，但代码必须继续处理。

实测（见 §12）：新插入行 `t_infomask = 2048`（`HEAP_XMAX_INVALID`）；`VACUUM FREEZE` 后 `= 2816`（追加 0x0300），`t_xmin` 数值不变。

---

## 4. cutoffs 体系：`vacuum_get_cutoffs()`

| cutoff                    | 计算（默认值）                                                                | 语义                                 |
| ------------------------- | ----------------------------------------------------------------------------- | ------------------------------------ |
| `OldestXmin`              | `GetOldestNonRemovableTransactionId()`（≈ nextXID）                           | 死元组回收视界；**逐元组冻结视界**   |
| `OldestMxact`             | `GetOldestMultiXactId()`                                                      | multi 版                             |
| `FreezeLimit`             | `nextXID - vacuum_freeze_min_age`（5000 万），并 clamp 到 ≤ `OldestXmin`      | XID < 它 ⇒ **必须冻结**              |
| `MultiXactCutoff`         | `nextMXID - vacuum_multixact_freeze_min_age`（500 万），clamp ≤ `OldestMxact` | MXID 版                              |
| `relfrozenxid/relminmxid` | `pg_class` 当前值                                                             | 本次推进的起点，也是扫描中的安全下界 |

两个容易混淆的视界要分清：

- **`FreezeLimit` 决定「是否必须冻结」**：`heap_tuple_should_freeze()` 检查 xmin/xmax/xvac 及 multi 每个成员，任一 < `FreezeLimit`（或 MXID < `MultiXactCutoff`）⇒ 页 `freeze_required = true`，VACUUM 无权跳过；
- **`OldestXmin` 决定「冻到多老」**：`freeze_xmin = xmin < OldestXmin`。既然已决定动手，就顺手把所有 < `OldestXmin` 的 XID 全冻掉，让 `relfrozenxid` 尽量推远，推迟下次劳动。`FreezeLimit ≤ OldestXmin`，所以后者更宽。

age 参数的 GUC 约束（防 anti-wraparound 过于频繁）：`freeze_min_age ≤ autovacuum_freeze_max_age / 2`；`freeze_table_age ≤ 0.95 × autovacuum_freeze_max_age`。

---

## 5. 触发路径与 aggressive

### 5.1 谁触发

- **普通 VACUUM**：扫到哪冻到哪，`freeze_required` 的页必须冻；
- **autovacuum**：某表 `relfrozenxid` 年龄超过 `autovacuum_freeze_max_age`（默认 2 亿）⇒ 强制发起 anti-wraparound vacuum（`is_wraparound = true`，可绕开多数成本节流）；空表也要做——否则它自己就是全库最老；
- **`VACUUM FREEZE`**：四个 freeze age 全置 0 ⇒ aggressive + 尽量全冻。

### 5.2 aggressive 的含义

`vacuum_get_cutoffs()` 返回值：`relfrozenxid ≤ nextXID - freeze_table_age`（`vacuum_freeze_table_age` 默认 1.5 亿）时为 aggressive。**aggressive = 「必须把 relfrozenxid 至少推进到 FreezeLimit」**，因此：

- `lazy_scan_skip()` 跳页规则收紧：非 aggressive 可跳过 all-visible 区间（≥ 32 页连续）；aggressive **只能跳 all-frozen 页**——all-visible 页仍可能有 < FreezeLimit 的未冻结 XID；
- 拿不到 cleanup lock 的页：`lazy_scan_noprune()` 只收集 LP_DEAD 后返回 false，**等待并重试** `lazy_scan_prune()`（普通 VACUUM 则先跳过）；
- `VACUUM (DISABLE_PAGE_SKIPPING)` 也强制 aggressive 且连 all-frozen 页都不跳。

> 注意：手工 `VACUUM` 不读表级 reloption 的 `autovacuum_freeze_*`，那是 autovacuum 专用；手工路径用 GUC（`SET vacuum_freeze_table_age = 0` 即可演示 aggressive）。

---

## 6. freeze 怎么做：`lazy_scan_prune()` 两阶段

### 6.1 prepare（锁内、临界区外，可查 clog / multixact）

prune 之后对每个 `LP_NORMAL` 元组先过 `HeapTupleSatisfiesVacuum`（DEAD 的早被 prune/删除，走不到 freeze），再调 `heap_prepare_freeze_tuple()`，在内存中攒 `HeapTupleFreeze` 计划（目标 xmax / infomask / frzflags / checkflags），同时维护页级 `HeapPageFreeze` 状态。逐字段判定：

| 字段          | 冻结条件                 | 动作                                                           |
| ------------- | ------------------------ | -------------------------------------------------------------- |
| xmin          | `xmin < OldestXmin`      | `infomask \|= HEAP_XMIN_FROZEN`；执行时复核 committed          |
| xmax（普通）  | `xmax < OldestXmin`      | 清空 xmax，置 `HEAP_XMAX_INVALID`；非 lock-only 则复核 aborted |
| xmax（multi） | 见 `FreezeMultiXactId()` | 四种结果，见下                                                 |
| xvac          | 存在即冻                 | 写 `FrozenTransactionId` / Invalid                             |

- committed updater 的 xmax 不可能 < `OldestXmin`（否则整元组早已 DEAD 被移除），所以能走到 freeze_xmax 的只有 lock-only 与 aborted updater；
- **checkflags 复核不信任 hint bit**：`HEAP_FREEZE_CHECK_XMIN_COMMITTED` / `HEAP_FREEZE_CHECK_XMAX_ABORTED` 在执行阶段的临界区**外**查 clog（昂贵，不能反复做），失败即 `DATA_CORRUPTED`。

`FreezeMultiXactId()` 的四种结果（除 NOOP 外都强制 `freeze_required`）：

| flags                 | 场景                               | 动作                                               |
| --------------------- | ---------------------------------- | -------------------------------------------------- |
| `FRM_NOOP`            | multi 还新（成员可能 in-progress） | 原样保留；只回退 NoFreeze 追踪器                   |
| `FRM_INVALIDATE_XMAX` | 老 multi 且 lock-only / 成员皆可弃 | 直接清空 xmax                                      |
| `FRM_RETURN_IS_XID`   | 只剩一个 updater 成员              | 用普通 XID 替换 multi（可附 `FRM_MARK_COMMITTED`） |
| `FRM_RETURN_IS_MULTI` | ≥ 2 个存活成员                     | **分配新 multi** 只含存活成员（尽量避免）          |

主动处理 multi 是为了不让老 multi 拖住 `relminmxid` 并减少 SLRU 反复访问。

### 6.2 decide & execute（临界区内原子完成）

prepare 完成后按页决策，**满足任一条件即走 freeze path**：

```text
pagefrz.freeze_required                                    -- 有 XID < FreezeLimit，必须冻
OR tuples_frozen == 0                                      -- 无计划可执行，零成本；且页可因此置 all-frozen
OR (all_visible && all_frozen && prune 已产生 FPI)          -- 反正要写 WAL，顺手冻满以置 all-frozen
```

- **freeze path**：`heap_freeze_execute_prepared()` 临界区内逐个 `heap_execute_freeze_tuple()` + WAL（§7）；页级追踪器取 `FreezePageRelfrozenXid/RelminMxid`；
- **no-freeze path**：追踪器取 `NoFreezePage*`（回退到页内仍残留的最老 XID），并强制 `all_frozen = false` —— **只有走过 freeze path 的页才可能被标记 VM all-frozen**。

`totally_frozen`（每个存活元组的 xmin/xmax 均已冻或将冻）累积出页级 `all_frozen`；连同 `all_visible` 供 `lazy_scan_heap` 决定 `visibilitymap_set(..., ALL_VISIBLE | ALL_FROZEN)`。

---

## 7. WAL：`XLOG_HEAP2_FREEZE_PAGE`

冻结**不是 hint**，必须 redo（源码注释明言）：relfrozenxid 推进 + clog 截断后，一旦崩溃丢掉冻结记录，xmin 的状态将无处可查。记录结构：

```text
xl_heap_freeze_page { snapshotConflictHorizon, isCatalogRel, nplans }
plans[]   /* 去重后的冻结计划: xmax / infomask / infomask2 / frzflags / ntuples */
offsets[] /* 按 plan 分组的元组偏移 */
```

- **计划去重**（`heap_log_freeze_plan`）：同页大量元组往往共享同一冻结动作，排序合并后 WAL 里只存一份 plan + 一串 offset；
- `snapshotConflictHorizon`：页将 all-frozen 时用 `visibility_cutoff_xid`（该值随即清空，后续 `visibilitymap_set` 可传 Invalid）；否则保守取 `OldestXmin - 1`，避免 hot standby 误冲突；
- redo（`heap_xlog_freeze_page`）：hot standby 先 `ResolveRecoveryConflictWithSnapshot`，再逐 plan 逐 offset 重放 `heap_execute_freeze_tuple`。

---

## 8. relfrozenxid 推进与 VM all-frozen

### 8.1 NewRelfrozenXid 追踪器

`vacrel->NewRelfrozenXid` 初始 = `OldestXmin`（最乐观），随扫描中**未冻结而残留**的老 XID（含 multi 成员）逐页回退；两种页级结局各有一套追踪器（FreezePage\* / NoFreezePage\*），按 §6.2 的决策择一提交。收尾规则：

- **aggressive**：最终值必须 ≥ `FreezeLimit`（有断言保证）；若因跳过 all-visible 页（`skippedallvis`）等导致无法证明安全，则**保留原 relfrozenxid**；
- **非 aggressive**：可推进任意幅度，也可不推进；
- `vac_update_relstats()` 写回 `pg_class`；全库各库 `datfrozenxid` 的最小值驱动 `vac_truncate_clog()`。

### 8.2 VM all-frozen

- 置位条件：freeze path + `all_visible` + `all_frozen` + 无 LP_DEAD；`lazy_scan_heap` 持堆页锁置 `PD_ALL_VISIBLE` 并 `visibilitymap_set`（WAL：`log_heap_visible`）；
- all-frozen 只能建在 all-visible 之上；DML / tuple lock 破坏页则清位（见 [VM](../src/backend/access/heap/01_vm.md)）；
- 收益：aggressive VACUUM 也**能跳过 all-frozen 页**（不可能再含 < FreezeLimit 的 XID）——freeze 是一次投入、长期免扫。

---

## 9. wraparound 防线阶梯

`SetTransactionIdLimit()`（`varsup.c`）按全库最老 `datfrozenxid` 计算各道防线：

| 防线       | 阈值（默认）                                 | 动作                                                    |
| ---------- | -------------------------------------------- | ------------------------------------------------------- |
| autovacuum | `oldest + autovacuum_freeze_max_age`（2 亿） | 触发 anti-wraparound autovacuum（并逐库连续处理）       |
| WARNING    | `wrapLimit - 4000 万`                        | "database must be vacuumed within N transactions"       |
| 停止分配   | `wrapLimit - 300 万`                         | 拒绝分配新 XID（只读不受影响；单用户模式留给 DBA 抢救） |
| wrapLimit  | `oldest + 2³¹`                               | 理论回卷点，不可越过                                    |

**failsafe**（`vacuum_xid_failsafe_check`，PG 12+）：表 `relfrozenxid` 老于 `max(vacuum_failsafe_age, 1.05 × autovacuum_freeze_max_age)`（默认 16 亿）时，进行中的 aggressive VACUUM 放弃索引清理与截断，只求尽快推进 `relfrozenxid`。

---

## 10. 核心函数

| 函数                             | 作用                                                             |
| -------------------------------- | ---------------------------------------------------------------- |
| `vacuum_get_cutoffs()`           | 计算 OldestXmin / FreezeLimit / MultiXactCutoff，判定 aggressive |
| `lazy_scan_prune()`              | prune + 逐元组 prepare + 页级决策 + 执行 + VM 置位               |
| `lazy_scan_noprune()`            | 无 cleanup lock 时的降级扫描；aggressive 下可要求重试            |
| `heap_prepare_freeze_tuple()`    | 单元组冻结计划（可读 multixact / 产生新 multi）                  |
| `heap_tuple_should_freeze()`     | 是否存在 < FreezeLimit 的 XID ⇒ 页必须冻结；维护 NoFreeze 追踪器 |
| `FreezeMultiXactId()`            | multi xmax 的四种处置                                            |
| `heap_freeze_execute_prepared()` | 临界区内原子执行全页计划 + 写 `XLOG_HEAP2_FREEZE_PAGE`           |
| `heap_execute_freeze_tuple()`    | 按计划改写单个 tuple 头                                          |
| `heap_freeze_tuple()`            | prepare+execute 一步到位、不写 WAL（CLUSTER / rewriteheap 用）   |
| `heap_xlog_freeze_page()`        | redo                                                             |
| `SetTransactionIdLimit()`        | wraparound 防线阈值（varsup.c）                                  |

---

## 11. 流程概览

```text
ExecVacuum | vacuum
    vacuum_rel | table_relation_vacuum
        heap_vacuum_rel | lazy_scan_heap
            vacuum_get_cutoffs        /* OldestXmin, FreezeLimit, MultiXactCutoff; aggressive? */
            lazy_scan_skip            /* aggressive 只能跳 all-frozen 页 */
            lazy_scan_prune           /* Prune, freeze, and count tuples */
                heap_page_prune       /* 先回收 HOT 死版本 */
                HeapTupleSatisfiesVacuum
                heap_prepare_freeze_tuple   /* 每个 LP_NORMAL 元组 */
                    heap_tuple_should_freeze      /* freeze_required? */
                    FreezeMultiXactId             /* xmax 是 multi */
                [decide: freeze_required || tuples_frozen==0 || FPI]
                heap_freeze_execute_prepared
                    heap_execute_freeze_tuple     /* 改写 tuple 头 */
                    XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_FREEZE_PAGE)
                visibilitymap_set            /* ALL_VISIBLE | ALL_FROZEN */
            vac_update_relstats       /* 推进 pg_class.relfrozenxid / relminmxid */
    vac_truncate_clog                  /* 按全库最老 datfrozenxid 截断 clog */
```

---

## 12. 可复现实验（PG 16.11 实测）

### 12.1 观察 infomask 与 relfrozenxid

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;

DROP TABLE IF EXISTS test_freeze;
CREATE TABLE test_freeze (id int PRIMARY KEY, val int)
  WITH (autovacuum_enabled = off);

INSERT INTO test_freeze VALUES (1, 1), (2, 2), (3, 3);

-- 新插入: t_infomask = 2048 (HEAP_XMAX_INVALID), 无 xmin-committed hint
SELECT lp, t_xmin, t_xmax, t_infomask, to_hex(t_infomask)
FROM heap_page_items(get_raw_page('test_freeze', 0));

SELECT relfrozenxid, age(relfrozenxid) FROM pg_class WHERE relname = 'test_freeze';

VACUUM FREEZE test_freeze;

-- t_xmin 不变; t_infomask = 2816 = 2048 | 0x0300 (HEAP_XMIN_FROZEN)
SELECT lp, t_xmin, t_xmax, t_infomask, to_hex(t_infomask)
FROM heap_page_items(get_raw_page('test_freeze', 0));

SELECT relfrozenxid, age(relfrozenxid) FROM pg_class WHERE relname = 'test_freeze';

-- VM: 页已 all-visible + all-frozen（需 pg_visibility 扩展）
SELECT blkno, all_visible, all_frozen FROM pg_visibility_map('test_freeze');
```

### 12.2 lock-only xmax 被 freeze 清除

```sql
BEGIN; SELECT * FROM test_freeze WHERE id = 1 FOR SHARE; COMMIT;

-- lp1: t_xmax = 加锁事务 XID（lock-only）
SELECT lp, t_xmin, t_xmax, t_infomask
FROM heap_page_items(get_raw_page('test_freeze', 0));

VACUUM FREEZE test_freeze;

-- lp1: t_xmax = 0 —— freeze_xmax 路径清掉 lock-only xmax
SELECT lp, t_xmin, t_xmax, t_infomask
FROM heap_page_items(get_raw_page('test_freeze', 0));
```

（要观察到真正的 multi xmax，需要两个并发会话先后 `FOR SHARE` / `FOR UPDATE` 再提交。）

### 12.3 aggressive 与 VACUUM VERBOSE 输出

```sql
SET vacuum_freeze_table_age = 0;
VACUUM VERBOSE test_freeze;
-- INFO:  aggressively vacuuming ...
-- new relfrozenxid: 14661, which is N XIDs ahead of previous value
-- frozen: 0 pages ... had 0 tuples frozen   <- 冻过之后再次 FREEZE 大多无事可做
```

### 12.4 pg_waldump 观察 FREEZE_PAGE 记录

```sql
SELECT pg_current_wal_lsn();          -- 记下起点
UPDATE test_freeze SET val = val + 1 WHERE id = 2;  -- 产生新版本
VACUUM FREEZE test_freeze;
SELECT pg_current_wal_lsn();          -- 记下终点
```

```text
$ pg_waldump -p $PGDATA -s <起点> -e <终点> | grep -E 'PRUNE|FREEZE'
rmgr: Heap2  ... desc: PRUNE  snapshotConflictHorizon: 14661, nredirected: 1, ... redirected: [2->4] ...
rmgr: Heap2  ... desc: FREEZE_PAGE snapshotConflictHorizon: 14661, nplans: 1,
                 plans: [{ xmax: 0, infomask: 11008, infomask2: 32770, ntuples: 1, offsets: [4] }], ...
```

HOT 新版本（offset 4）被一条去重后的 plan 冻结：`infomask 11008 = 0x2B00`（`HEAP_XMIN_FROZEN | HEAP_XMAX_INVALID | HEAP_UPDATED`）。

### 12.5 Call Stack

```c
ExecVacuum | vacuum
    vacuum_rel | table_relation_vacuum
        heap_vacuum_rel | lazy_scan_heap | lazy_scan_prune
            heap_prepare_freeze_tuple /* prepare per-tuple freeze plan */
                heap_tuple_should_freeze /* should VACUUM freeze page? */
                FreezeMultiXactId /* what to do with multi xmax */
            heap_freeze_execute_prepared /* execute all plans atomically */
	            heap_execute_freeze_tuple /* set xmax/infomask/infomask2, xvac */
	            XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_FREEZE_PAGE)
            visibilitymap_set(rel, blkno, ..., VISIBILITYMAP_ALL_FROZEN)
	    vac_update_relstats /* advance pg_class.relfrozenxid */
```

---

## 13. 相关笔记

[XID](../src/backend/access/transam/05_xid.md) · [CLOG](../src/backend/access/transam/09_clog.md) · [MVCC Visibility](../src/backend/access/transam/08_mvcc_visibility.md) · [Page Prune](../src/backend/access/heap/03_prune.md) · [Lazy VACUUM](../src/backend/access/heap/04_vacuumlazy.md) · [VM](../src/backend/access/heap/01_vm.md) · [Heap AM](../src/backend/access/heap/heap.md) · [trace: VM](../src/traces/05_vm.md)

**最后更新**: 2026-09-02 | **适用版本**: PostgreSQL 16.x（对照 `REL_16_11` 源码）
