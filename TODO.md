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

- why: optimizer
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
- why: nbtree

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
- how: VACUUM

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
