# Prune

## Case

```sql
DROP TABLE IF EXISTS test_prune;

CREATE TABLE test_prune (id int PRIMARY KEY, val int)
  WITH (autovacuum_enabled = off, fillfactor = 100);

INSERT INTO test_prune values (1, 1), (2, 2), (3, 3);

-- HOT 更新，产生 dead heap-only tuple（不增索引项）
UPDATE test_prune SET val = val * 10 WHERE id = 2;

DELETE from test_prune where id = 3;

VACUUM test_prune;
```

## Call Stack

```c
ExecVacuum | vacuum
    vacuum_rel | table_relation_vacuum
        heap_vacuum_rel | lazy_scan_heap | lazy_scan_prune
            heap_page_prune /* Prune and repair fragmentation in the specified page. */
	            heap_prune_chain /* Process this item or chain of items */
	            heap_page_prune_execute /* Perform the actual page changes needed by heap_page_prune */
		            ItemIdSetRedirect /* Update all redirected line pointers */
		            ItemIdSetDead /* Update all now-dead line pointers */
		            ItemIdSetUnused /* Update all now-unused line pointers */
		            PageRepairFragmentation
			            compactify_tuples
	            PageClearFull
	            XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_PRUNE);
            
```
