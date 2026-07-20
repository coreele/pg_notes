# 学习进度表

> 依据：`TODO.md` 素材清单 + `src/` / `temp/` / `traces/` 现有笔记  
> 评估日：2026-07-16  
> 等级：`掌握` > `较好` > `入门` > `薄弱` / `未开始`  
> 本文件独立于 `TODO.md`，不替代素材池。

---

## 总览

| 模块 | 整体 | 一句话 |
|------|------|--------|
| **wal** | **掌握（核心四课）** | Record / FPW / LSN / MTR 已闭环；缺流复制 |
| **transaction** | **较好** | MVCC / 隔离 / 快照 / 可见性笔记较全；CLOG、锁分层待钉死 |
| **storage** | **较好（局部）** | Page / Buffer 有深度；Heap 组织、VM/FSM、VACUUM、TOAST 缺口大 |
| **access** | **入门～较好** | nbtree 有 page/plan/code；索引类型全景弱 |
| **executor** | **较好** | Pipeline / Portal / Slot 有笔记；物化与 Sort 未专题 |
| **memory** | **入门～较好** | mmgr / Clock Sweep 有料；syscache、失效、DSA 未系统化 |
| **parser / analyzer** | **入门** | 概览 + analyze；Flex/Bison、expr、func 未深挖 |
| **optimizer** | **薄弱** | 仅 overview |
| **others / distributed** | **未开始** | Parallel / JIT / Neon / Citus |
| **meta / traces** | **较好** | 编译启动 + INSERT/DELETE/UPDATE 链路，作实验锚点 |

**当前主线建议**：先收尾 WAL（流复制），再补 storage 空洞与 transaction 锁/CLOG，最后才进 optimizer。

---

## 分模块进度

### wal

| TODO 条目 | 笔记落点 | 等级 | 已掌握 | 应强化 |
|-----------|----------|------|--------|--------|
| How: WAL Record Structure & Insertion ✔ | `temp/wal_record.md`；`traces/01_insert.md` | **掌握** | 注册/组装、Main vs BufData、`XLogInsert` 路径、waldump 字段 | 跨页记录、多种 rmgr 对照 |
| what & why & how: Full Page Writes ✔ | `transam/10_full_page_writes.md` | **掌握** | torn page、`page_lsn <= RedoRecPtr`、FPI/APPLY、备份强制 FPW | 自己跑出「checkpoint 后首次改页出现 FPI」实验 |
| What & Why: XLogRecPtr (LSN) ✔ | `transam/11_xlogrecptr_lsn.md` | **掌握** | Insert/Write/Flush、`xl_prev`=上条 start、`pd_lsn`=EndRecPtr | 三级指针实验拉开差距；Redo 与 checkpoint.redo 对照 |
| What & Why: Mini-Transaction ✔ | `transam/12_mini_transaction.md` | **较好** | atomic action、临界区序、与用户事务分层、incomplete split 边界 | 对着 `_bt_split` / `XLOG_BTREE_SPLIT` 跑一刀多页实验 |
| How: Streaming Replication & Log Decoding | `09_wal_recovery.md`（HA 表） | **薄弱** | 故障域/恢复层级概念 | walsender/walreceiver、replay LSN、logical decoding 入口 |
| （旁路）Recovery / Checkpoint | `09_wal_recovery.md`、overview 中 checkpoint | **入门** | RTO/RPO 分层、checkpoint 触发 | crash recovery 源码路径、restartpoint |

### transaction

| TODO 条目 | 笔记落点 | 等级 | 已掌握 | 应强化 |
|-----------|----------|------|--------|--------|
| How: CLOG | 零散提及（commit 链路） | **入门** | 提交改 clog bit、与 WAL 顺序直觉 | `TransactionIdCommitTree`、`pg_xact` 布局、组提交 |
| Why: Non-overwrite MVCC | `07_mvcc_snapshot`、`08_mvcc_visibility`、`06_iso` | **较好** | 快照、可见性、隔离异常 | 明确写成「非覆盖」专题：旧版本链、HOT、与 undo 对比 |
| How: LWLock vs SpinLock vs Heavyweight | `storage/lmgr/*` | **较好** | 行锁/冲突、UPDATE 锁路径 | 三种锁适用场景对照表 + 源码入口对照 |
| （旁路）XID / VXID / 状态机 | `02`–`05`、`03_state` | **较好** | 事务状态、延迟分配 XID | subxact、2PC |

### storage

| TODO 条目 | 笔记落点 | 等级 | 已掌握 | 应强化 |
|-----------|----------|------|--------|--------|
| why: Heap File Organization | page layout、insert 链路 | **入门** | 8KB page、item pointer、文件扩展 | heap 页内布局与 FSM 取页策略专题 |
| why: VM and FSM | — | **薄弱** | — | visibility map / free space map 何时读写 |
| what & when: Deduplication | — | **未开始** | — | B-tree posting list 去重时机 |
| why & how: VACUUM | — | **薄弱** | 长事务卡住清理的直觉 | freeze、索引清理、autovacuum |
| Why & How: TOAST | — | **未开始** | — | 超大字段外置、chunk、与 WAL |
| （旁路）Page / Buffer | `page/00_layout`、`buffer/*` | **较好** | pageinspect、命中/未命中、Clock Sweep 选 victim | dirty / pin / IO 状态机串起来 |

### access

| TODO 条目 | 笔记落点 | 等级 | 已掌握 | 应强化 |
|-----------|----------|------|--------|--------|
| what: index types | — | **薄弱** | — | btree / hash / gin / gist / brin 选型表 |
| why & how: nbtree | `nbtree/00–03` | **较好** | 页结构、扫描计划实验 | split/merge、与 MTR/WAL 联动（接下一课） |

### executor

| TODO 条目 | 笔记落点 | 等级 | 已掌握 | 应强化 |
|-----------|----------|------|--------|--------|
| How: Demand-Driven Pipeline | `executor/01_pipeline` | **较好** | Volcano pull、Portal→Executor | 并行下的 Gather、异步节点 |
| What & Why: TupleTableSlot | pipeline / state 中 | **入门** | Slot 统一表/索引行 | virtual / heap / minimal 形态与拷贝语义 |
| How: Materialize & Sort | — | **未开始** | — | 何时物化、sort spill、与内存上下文 |

### memory

| TODO 条目 | 笔记落点 | 等级 | 已掌握 | 应强化 |
|-----------|----------|------|--------|--------|
| how & why: Clock Sweep | `buffer/02_victim` | **较好** | usage_count / refcount 选 victim | 与 BgWriter、checkpoint 刷脏关系 |
| how: Deadlock Detector | — | **未开始** | — | 等待图、检测周期 |
| how: syscache | — | **薄弱** | — | CatCache、查找路径 |
| how: cache invalidation | — | **未开始** | — | SI 消息、本地缓存失效 |
| What: Double Buffering | FPW/overview 提及 | **薄弱** | 与半写对比直觉 | PG 为何不做 MySQL 式 doublewrite |
| （旁路）mmgr / ResOwner | `utils/mmgr/*`、`resowner/*` | **较好** | 上下文层级、查询内存 | DSA（TODO 顶部条目） |

### parser / analyzer

| TODO 条目 | 笔记落点 | 等级 | 已掌握 | 应强化 |
|-----------|----------|------|--------|--------|
| How: Flex & Bison | `parser/00_overview` | **入门** | RawStmt 树形态 | 词法/文法入口文件、生成流程 |
| How: Query Rewrite | — | **薄弱** | — | 规则、视图展开 |
| how: expr / func call | `parser/01_analyze` | **入门** | analyze 阶段存在感 | 表达式变形、函数解析 |

### optimizer

| TODO 条目 | 笔记落点 | 等级 | 已掌握 | 应强化 |
|-----------|----------|------|--------|--------|
| how: optimizer | `optimizer/00_overview` | **薄弱** | 模块地图 | Path / RelOptInfo 主循环 |
| how: Join Order | — | **未开始** | — | 动态规划 / GEQO |
| How: Path to Plan | — | **未开始** | — | `create_plan` |

### others / distributed / 顶部杂项

| TODO 条目 | 等级 | 应强化 |
|-----------|------|--------|
| Why: Process-based Model | **入门**（arch/boot 有） | postmaster / backend 模型专题 |
| What & Why: DSA | **未开始** | 并行查询前置 |
| Parallel Query / JIT | **未开始** | 选修 |
| Neon / Citus | **未开始** | 选修 / 后期 |

---

## 能力剖面（相对目标）

```text
WAL 持久化主链     █████████████░░░  强（缺复制）
事务 / MVCC        ████████░░░░░░░░  中上（缺 CLOG、锁对照）
存储 / 页 / Buffer ███████░░░░░░░░░  中（缺 VACUUM/TOAST/VM）
访问方法 nbtree    ██████░░░░░░░░░░  中（缺 split+WAL）
执行器             ██████░░░░░░░░░░  中（缺物化/Sort）
解析 / 优化        ███░░░░░░░░░░░░░  弱
分布式 / 并行      ░░░░░░░░░░░░░░░░  未开始
```

---

## 建议强化顺序

| 优先级 | 主题 | 原因 |
|--------|------|------|
| **P0** | Streaming Replication & Log Decoding | WAL 模块收尾；复制位点依赖 LSN |
| **P1** | Heap + VM/FSM + VACUUM | 存储与 MVCC 收尾；否则「版本谁清理」悬空 |
| **P1** | CLOG + 三种锁对照 | 事务模块 TODO 未闭合 |
| **P2** | TupleTableSlot + Materialize/Sort | 执行器从「链路」进「算子」 |
| **P2** | nbtree split（可与 MTR 合并） | access 从读进写路径 |
| **P3** | Optimizer Join Order + Costing | 查询编译后半段 |
| **选修** | Parallel / JIT / Neon | 有基础后再开 |

---

## 还应学的模块（相对 TODO 的缺口）

`TODO.md` 已覆盖查询编译、事务、存储、WAL 主线；下面是学透 **PG 内核源码** 时常见但清单里偏少/缺失的块。按与你当前进度的衔接排序。

### A. 运行时与进程（接 Process-based Model）

| 建议专题 | 源码锚点 | 为何要学 | 与现状关系 |
|----------|----------|----------|------------|
| Postmaster / Backend 生命周期 | `postmaster/`、`backend_startup` | 理解谁 fork、信号、崩溃后谁拉起 | TODO 顶部有 Process-based，笔记仅 arch 图 |
| 辅助进程分工 | checkpointer / bgwriter / walwriter / autovacuum / stats | WAL 刷盘、脏页、清理都靠它们 | 已知 Flush/checkpoint，未串进程 |
| Shared Memory 布局 | `ipci.c`、`shmem`、LWLock tranche | DSA 之前要懂固定共享区与动态区 | TODO 有 DSA，缺总图 |
| ProcArray / PGPROC | `procarray.c`、`proc.c` | 快照、锁等待、复制都挂在进程槽 | MVCC 较好，缺「谁在跑」 |

### B. 事务深化（接 CLOG / MVCC）

| 建议专题 | 源码锚点 | 为何要学 | 与现状关系 |
|----------|----------|----------|------------|
| MultiXact / 行锁共享 | `multixact.c` | `FOR SHARE`、多事务持锁 | 锁笔记有 UPDATE，缺 MultiXact |
| Subtrans / 子事务 | `subtrans.c`、SAVEPOINT | 回滚段、可见性边界 | 状态机较好，缺子事务 |
| XID wraparound / freeze | `vacuumlazy`、`varsup` | 生产致命题；与 VACUUM 绑定 | VACUUM 薄弱 |
| SSI / 谓词锁 | `predicate.c` | Serializable 真正实现 | 隔离级别有表，SSI 未拆 |
| 2PC | `twophase.c` | 分布式/外部事务入口 | 未开始 |

### C. 堆表与清理（接 storage TODO）

| 建议专题 | 源码锚点 | 为何要学 | 与现状关系 |
|----------|----------|----------|------------|
| Table AM / Heap AM | `tableam.h`、`heapam*.c` | INSERT 链路之上的抽象层 | 跟过 heap_insert，缺 AM 接口 |
| HOT / 页内 prune | `heapam_prune`、`heapam_visibility` | UPDATE 性能与版本链关键 | update trace 有，HOT 未专题 |
| Autovacuum 调度 | `autovacuum.c` | 谁触发 VACUUM/ANALYZE | VACUUM 条目应连带学 |
| Checksum / IO 同步方法 | `bufpage` checksum、`sync` | 与 FPW、`wal_sync_method` 对照 | FPW 已学，IO 语义可补 |

### D. 访问方法扩展（接 nbtree）

| 建议专题 | 源码锚点 | 为何要学 | 与现状关系 |
|----------|----------|----------|------------|
| Index AM API | `indexam`、`genam` | 统一扫描/插入接口 | 有 nbtree，缺抽象 |
| GIN / GiST / BRIN（选 1～2） | `access/gin` 等 | 与「index types」TODO 闭合 | 选型表尚未写 |
| Hash index（可选） | `access/hash` | 对比 btree 页分裂 | 低优 |

### E. 查询编译补强（接 parser / optimizer）

| 建议专题 | 源码锚点 | 为何要学 | 与现状关系 |
|----------|----------|----------|------------|
| Planner 代价与统计 | `costsize`、`plancat`、`ANALYZE` | Join Order 离开代价无意义 | optimizer 仅 overview |
| RelOptInfo / Path / RestrictInfo | `pathnode`、`indxpath` | 读懂 explain 与源码同构 | 未开始 |
| 分区裁剪 | `partprune`、`partition*.c` | 现代 schema 常见 | 清单无 |
| Rewrite：RLS / 视图 / 规则 | `rewrite*` | Query Rewrite TODO 具体化 | 薄弱 |

### F. 执行器算子（接 Pipeline / Slot）

| 建议专题 | 源码锚点 | 为何要学 | 与现状关系 |
|----------|----------|----------|------------|
| NestLoop / HashJoin / MergeJoin | `node*.c` | 三种连接如何 pull | Pipeline 有，算子无 |
| Agg / HashAgg / Window | `nodeAgg`、`nodeWindowAgg` | 分析负载入口 | 未开始 |
| Limit / Append / Gather | 对应 node | 并行与分区计划落点 | Parallel 选修前置 |

### G. 元数据与缓存（接 syscache）

| 建议专题 | 源码锚点 | 为何要学 | 与现状关系 |
|----------|----------|----------|------------|
| Relcache | `relcache.c` | 表定义缓存，DDL 后失效 | syscache 薄弱，应成对学 |
| Snapshot Invalidation (SI) | `inval.c`、`sinval*` | cache invalidation TODO 本体 | 未开始 |
| Catalog / bootstrap | `catalog/`、`bootstrap` | 系统表与 initdb | meta 有 boot，未深 |

### H. 复制与高可用（接 Streaming TODO）

| 建议专题 | 源码锚点 | 为何要学 | 与现状关系 |
|----------|----------|----------|------------|
| Replication Slot | `slot.c`、`replication/` | 保留 WAL、解码位点 | 流复制必修附件 |
| Timeline / archive recovery | `xlogrecovery`、`timeline` | PITR、升主 | recovery 入门 |
| Logical Decoding 插件模型 | `logical/`、output plugin | Decoding TODO 落地 | 未开始 |
| Base backup 协议 | `basebackup*.c`、`pg_basebackup` | 与 FPW/runningBackups 闭环 | 概念已有 |

### I. 选修 / 对照（接 others & distributed）

| 建议专题 | 说明 |
|----------|------|
| Parallel Query + DSA | 共享内存分配器在并行上下文中的用法 |
| JIT (LLVM) | 表达式/元组变形加速；先会 Slot/表达式 |
| FDW / 扩展钩子 | `fdwapi`、`*hook*`；理解插件面 |
| Neon / Citus | 存算分离 vs 分片；有单机内核后再读 |
| 对照 DuckDB / 列存 | blog 目标；向量化 vs Volcano |

---

## 扩展后的学习路线图（建议阶段）

```text
阶段 0  已做：INSERT 链路 · WAL Record · FPW · LSN · MTR
阶段 1  WAL 收尾：流复制/Slot →（可选）Logical Decoding
阶段 2  存储闭环：HeapAM/HOT → VM/FSM → VACUUM/freeze → TOAST
阶段 3  事务钉死：CLOG · MultiXact · 三锁 ·（可选）SSI/2PC
阶段 4  执行加深：Slot · Join 三算子 · Materialize/Sort · Agg
阶段 5  编译加深：统计/代价 · Join Order · Path→Plan · Rewrite
阶段 6  运行时：辅助进程 · Relcache/SI · Parallel/DSA
阶段 7  选修：JIT · Neon/Citus · 列存对照
```

---

## 近期可检验标准（WAL 已完成部分）

能口头/笔记答出即可视为巩固：

1. 一条 Heap INSERT WAL：`prev` / `lsn` / `pd_lsn` 各是什么  
2. 为何 `page_lsn <= RedoRecPtr` 要拍 FPI，而不是「刚变脏」  
3. Insert / Write / Flush 三级差在哪，COMMIT 推哪一级  
4. 一次涉及多页的修改，为何需要 MTR / critical section；B-tree split 为何拆成多条 WAL
5. （下一课）流复制位点与 Insert/Flush LSN 的关系  

---

**相关**：素材池 [`TODO.md`](./TODO.md) · 笔记根 [`src/SUMMARY.md`](./src/SUMMARY.md)
