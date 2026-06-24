# INDEX

```sql
drop table if exists tb;
create table tb (a int, b text);
insert into tb select n, '1234567890' from generate_series(1, 100000) as n;
create index idx on tb(a);
ANALYZE tb;

explain select * from tb where a = 5432;
                          QUERY PLAN                           
---------------------------------------------------------------
 Index Scan using idx on tb  (cost=0.29..8.31 rows=1 width=15)
   Index Cond: (a = 5432)
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
                ExecProject /* where a = 5432 and b <> 'aaa' */
PortalDrop
```
