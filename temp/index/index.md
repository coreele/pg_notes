# INDEX

```sql
create table tb (a int, b text);
insert into tb select n, n || '_text' from generate_series(1, 100000) as n;
create index idx on tb(a);
ANALYZE tb;
```
## index scan

```sql
explain select * from tb where a = 5432 and b = '5432_text';
                          QUERY PLAN                           
---------------------------------------------------------------
 Index Scan using idx on tb  (cost=0.42..8.44 rows=1 width=14)
   Index Cond: (a = 5432)
   Filter: (b = '5432_text'::text)
```

### width = 14?

```sql
select attname, avg_width from pg_stats where tablename='tb';

select avg(length(b)) from tb;
```

### execute

exec_simple_query

```c
PortalStart
    ExecutorStart | standard_ExecutorStart
        InitPlan | ExecInitNode | ExecInitIndexScan
            indexstate->ss.ps.ExecProcNode = ExecIndexScan;
            ExecOpenScanRelation
            index_open
            ExecIndexBuildScanKeys
PortalRun | PortalRunSelect
    ExecutorRun | standard_ExecutorRun
        ExecutePlan | ExecProcNode
            ExecIndexScan | ExecScan(.., IndexNext : ExecScanAccessMtd, ..)
                ExecScanFetch
                    IndexNext
                        index_beginscan
                        index_getnext_slot
                            index_getnext_tid
                                btgettuple
                                    _bt_first /* or _bt_next */
                                        _bt_search
                                            _bt_getroot
                                            _bt_binsrch
                                                _bt_compare
                                            child = BTreeTupleGetDownLink(itup);
                                                ItemPointerGetBlockNumberNoCheck
                                                    BlockIdGetBlockNumber
                                        _bt_binsrch
                            index_fetch_heap
                                table_index_fetch_tuple
                                    heapam_index_fetch_tuple
                                        heap_hot_search_buffer
                ExecQual
                ExecProject
PortalDrop
```

## Index Only Scan

```sql
explain select a from tb where a = 5432;
                            QUERY PLAN                             
-------------------------------------------------------------------
 Index Only Scan using idx on tb  (cost=0.29..8.31 rows=1 width=4)
   Index Cond: (a = 5432)
```
