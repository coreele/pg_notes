# TODO

- Why: Process-based Model
- What & Why: DSA (Dynamic Shared Memory Allocator)
- How: Aux Processes (checkpointer / bgwriter / walwriter / autovacuum)
- What: Shared Memory & ProcArray

## parser

- How: Flex & Bison
- How: Query Rewrite
- How: RLS / View / Rule Rewrite

## analyzer

- how: expr
- how: func call

## optimizer

- how: optimizer
- how: Join Order
- How: Path to Plan Conversion
- How: Costing & Statistics (ANALYZE / pg_statistic)
- How: Partition Pruning

## executor

- How: Demand-Driven Pipeline
- What & Why: TupleTableSlot
- How: Materialize & Sort (Material Nodes)
- How: Join Nodes (NestLoop / HashJoin / MergeJoin)
- How: Agg / HashAgg / Window

## transaction

- How: CLOG ✔
- Why: Non-overwrite MVCC
- How: LWLock vs. SpinLock vs. Heavyweight Lock
- What & Why: MultiXact
- How: Subtrans / SAVEPOINT
- Why & How: XID Wraparound & Freeze
- How: SSI (Serializable / Predicate Lock)
- How: Two-Phase Commit

## access

- what: index types
- why & how: nbtree
- What: Table AM / Index AM API
- How: HOT & Heap Prune
- what & when: GIN or GiST or BRIN

## memory

- how & why: Clock Sweep
- how: Deadlock Detector
- how: syscache
- how: Relcache
- how: cache invalidation
- What: Double Buffering

## storage

- why: Heap File Organization
- why: VM and FSM
- what & when: Deduplication
- why & how: VACUUM
- Why & How: TOAST
- How: Autovacuum
- What: Data Checksums & Sync Method（对照 FPW）

## wal

- How: WAL Record Structure & Insertion ✔
- what & why & how: Full Page Writes ✔
- What & Why: XLogRecPtr (LSN) ✔
- What & Why: Mini-Transaction ✔
- How: Crash Recovery Redo Path ✔
- How: Base Backup ✔
- How: Streaming Replication & Log Decoding ✔
- What: Replication Slot & Timeline ✔

## others

- how & when: Parallel Query
- What & when & why: JIT Compilation
- What: FDW / Extension Hooks（选修）

## distributed

- [neon](https://github.com/neondatabase/neon)
- [citus](https://github.com/citusdata/citus)

## blog

- [Scaling PostgreSQL](https://openai.com/index/scaling-postgresql/?ref=dailydev)
- **PostgreSQL**：理解经典关系数据库内核（存储、事务、优化器、执行器）。
- **DuckDB**：学习现代单机分析数据库（向量化执行、列存、SIMD）。
- **ClickHouse** —— 学现代列存实现和高性能执行器。
- **StarRocks 或 Apache Doris**：学习现代 MPP OLAP（分布式执行、Shuffle、Pipeline）。
- **Snowflake/BigQuery**：了解云原生分析数据库的计算存储分离架构。
