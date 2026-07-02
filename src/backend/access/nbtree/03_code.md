# INDEX execute

```sql
drop table if exists tb;
create table tb (a int, b text);
insert into tb select n, '1234567890' from generate_series(1, 100000) as n;
create index idx on tb(a);
ANALYZE tb;

explain select * from tb where a between 5000 and 5001;
                          QUERY PLAN
---------------------------------------------------------------
 Index Scan using idx on tb  (cost=0.29..8.33 rows=2 width=15)
   Index Cond: ((a >= 5000) AND (a <= 5001))
```

## IndexNext

- `index_getnext_tid`: 获取 tid
- `index_fetch_heap`: 回表获得原始数据

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
                            index_getnext_tid /* get tid */
                                btgettuple
                            index_fetch_heap /* get tuple */
                                table_index_fetch_tuple
                                    heapam_index_fetch_tuple
                                        heap_hot_search_buffer
                ExecQual
                ExecProject /* where a = 5432 and b <> 'aaa' */
PortalDrop
```

## btgettuple

- `_bt_first`: Find the first item in a scan
- `_bt_next`: Get the next item in a scan

```c
index_getnext_tid
    btgettuple
        _bt_first /* or _bt_next */
            _bt_search
                _bt_getroot
                _bt_binsrch /* binary search */
                    _bt_compare
                child = BTreeTupleGetDownLink(itup);
                    ItemPointerGetBlockNumberNoCheck
                        BlockIdGetBlockNumber
            _bt_binsrch
            _bt_readpage /* get tid */
                _bt_checkkeys
                _bt_saveitem
```
