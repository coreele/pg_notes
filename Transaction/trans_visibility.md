## insert | select

```sql
drop table if exists tb;
create table tb(a int);

begin;
insert into tb values(1);
commit;

select * from tb; -- 触发延迟更新 t_infomask

begin;
insert into tb values(2);
-----------------------------: psql2: select * from tb; -- 1 可见，2 不可见; 由 HeapTupleSatisfiesMVCC 判断
commit;
```

`HeapTupleSatisfiesMVCC`

```
SeqNext | table_scan_getnextslot | heap_getnextslot
    heapgettup_pagemode | heapgetpage
        HeapTupleSatisfiesVisibility
            HeapTupleSatisfiesMVCC
```

## PostgreSQL MVCC 可见性判断核心规则总结

PostgreSQL 中 `HeapTupleSatisfiesMVCC` 函数判断元组对当前快照可见性的逻辑，可以分为两大阶段：

## 1. 插入事务（XMIN）可见性校验

这是判断的第一阶段，用于确认元组的插入操作是否对当前快照可见。

- XMIN 已提交：
  - 若 XMIN 是冻结的事务 ID → 直接可见。
  - 若 XMIN 在快照的活跃事务列表中 → 不可见（视为未完成）。
- XMIN 未提交：
  - 若 XMIN 无效（事务已终止）→ 元组不可见。
  - 若 XMIN 是当前事务 → 检查命令 ID（Cmin），若 Cmin ≥ 快照起始命令 ID → 元组不可见（插入晚于扫描开始）。
  - 若 XMIN 在快照的活跃事务列表中 → 不可见。
  - 若 XMIN 已提交 → 标记 `HEAP_XMIN_COMMITTED` 并继续；若已终止 → 标记 `HEAP_XMIN_INVALID` 并返回不可见。
- 特殊处理（旧版本迁移标记）：
  对 `HEAP_MOVED_OFF`/`HEAP_MOVED_IN` 标记的元组，通过清理事务 ID（Xvac）判断有效性，并更新对应的提示位。


## 2. 删除/更新事务（XMAX）可见性校验

只有当插入事务校验通过后，才会进入这一阶段，用于确认元组的删除/更新操作是否影响可见性。

- XMAX 无效/仅锁状态：
  元组未被实际删除，直接返回可见。
- XMAX 是当前事务：
  检查命令 ID（Cmax），若 Cmax ≥ 快照起始命令 ID → 元组可见（删除晚于扫描开始），否则不可见。
- XMAX 在快照的活跃事务列表中：
  元组可见（视为删除操作未完成）。
- XMAX 已提交：
  元组不可见（删除/更新已生效）。
- XMAX 已终止：
  标记 `HEAP_XMAX_INVALID` 并返回可见。

## 核心原则

- 快照隔离：元组的可见性完全由当前事务的快照决定，只“看到”快照建立前已提交的插入，以及快照建立后未提交的删除。
- 提示位优化：通过 `HEAP_XMIN_COMMITTED`/`HEAP_XMAX_INVALID` 等提示位缓存事务状态，避免重复查询事务日志，提升性能。
- 事务 ID 生命周期：每个元组的 XMIN/XMAX 都对应事务的完整生命周期（活跃、提交、终止），函数会根据其状态逐步校验。

如果你需要，我可以帮你整理一份MVCC可见性判断的流程图，让整个判断逻辑更直观，需要吗？
