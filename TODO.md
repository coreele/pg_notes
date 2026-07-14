# TODO

- Why: Process-based Model
- What & Why: DSA (Dynamic Shared Memory Allocator)

## parser

- How: Flex & Bison
- How: Query Rewrite

## analyzer

- how: expr
- how: func call

## optimizer

- how: optimizer
- how: Join Order
- How: Path to Plan Conversion

## executor

- How: Demand-Driven Pipeline
- What & Why: TupleTableSlot
- How: Materialize & Sort (Material Nodes)

## transaction

- How: CLOG
- Why: Non-overwrite MVCC
- How: LWLock vs. SpinLock vs. Heavyweight Lock

## access

- what: index types
- why & how: nbtree

## memory

- how & why: Clock Sweep
- how: Deadlock Detector
- how: syscache
- how: cache invalidation
- What: Double Buffering



## storage

- why: Heap File Organization
- why: VM and FSM
- what & when: Deduplication
- why & how: VACUUM
- Why & How: TOAST



## wal

- How: WAL Record Structure & Insertion
- why: Full Page Writes
- How: Streaming Replication & Log Decoding
- What & Why: Mini-Transaction (MTR)
- XLogRecPtr (LSN)



## others

- how & when: Parallel Query
- What & when & why: JIT Compilation



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

