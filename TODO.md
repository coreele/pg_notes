# TODO

## meta

- What: Architecture ✔
- What: Code Structure ✔
- How: Compile & Debug ✔
- How: Boot (Postmaster → Backend) ✔

## arch

- Why: Process-based Model ✔
- What & Why: DSA (Dynamic Shared Memory Allocator)
- How: Aux Processes (checkpointer / bgwriter / walwriter / autovacuum)
- What: Shared Memory & ProcArray

## tcop

- What: Traffic Cop / Message Overview ✔

## parser

- What: Parser Overview ✔
- How: Analyze ✔
- How: Flex & Bison
- How: Query Rewrite
- How: RLS / View / Rule Rewrite

## analyzer

- how: expr
- how: func call
- What: pg_type / Typmod / Type OID
- How: Type Coercion & Casts (pg_cast)
- How: Function / Operator Type Resolution
- what & when: Polymorphism (anyelement / anyarray, etc.)
- What: Collation (optional)

## optimizer

- What: Optimizer Overview ✔
- how: optimizer
- how: Join Order
- How: Path to Plan Conversion
- How: Costing & Statistics (ANALYZE / pg_statistic)
- How: Partition Pruning

## executor

- What: Executor Overview ✔
- How: Demand-Driven Pipeline ✔
- What & Why: Executor / Portal State ✔
- What & Why: TupleTableSlot ✔
- How: Materialize & Sort (Material Nodes)
- How: Join Nodes (NestLoop / HashJoin / MergeJoin)
- How: Agg / HashAgg / Window

## transaction

- What: Transaction Overview ✔
- How: Transaction Process ✔
- What: Transaction State ✔
- What: Virtual XID ✔
- What: XID ✔
- How: Isolation ✔
- How: MVCC Snapshot ✔
- How: MVCC Visibility ✔
- How: CLOG ✔
- Why: Non-overwrite MVCC ✔
- How: LWLock vs. SpinLock vs. Heavyweight Lock ✔
- What & Why: MultiXact
- How: Subtrans / SAVEPOINT
- Why & How: XID Wraparound & Freeze
- How: SSI (Serializable / Predicate Lock)
- How: Two-Phase Commit

## wal

- What: WAL Recovery / Failure Domains ✔
- How: WAL Record Structure & Insertion ✔
- what & why & how: Full Page Writes ✔
- What & Why: XLogRecPtr (LSN) ✔
- What & Why: Mini-Transaction ✔
- How: Crash Recovery Redo Path ✔
- How: Base Backup ✔

## replication

- How: Streaming Replication & Log Decoding ✔
- What: Replication Slot & Timeline ✔

## access

- what: index types
- why & how: nbtree ✔
- What: Table AM / Index AM API
- How: HOT & Heap Prune
- what & when: GIN or GiST or BRIN

## memory

- What: MemoryContext / mmgr ✔
- What: ResourceOwner ✔
- how & why: Clock Sweep ✔
- how: Deadlock Detector
- how: syscache
- how: Relcache
- how: cache invalidation
- What: Double Buffering

## storage

- What: Page Layout ✔
- What: Page Checksums (README) ✔
- What: Buffer Manager Overview ✔
- why: Heap File Organization
- why: VM and FSM
- what & when: Deduplication
- why & how: VACUUM
- Why & How: TOAST
- How: Autovacuum
- What: Data Checksums & Sync Method (vs FPW)

## tools

- How: pageinspect ✔

## traces

- How: Query Overview ✔
- How: Insert ✔
- How: Delete ✔
- How: Update ✔
- How: Crash Recovery ✔

## others

- how & when: Parallel Query
- What & when & why: JIT Compilation
- What: FDW / Extension Hooks (optional)
