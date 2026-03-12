# Locks in update

```sql
update tb set a = 1;
```

1. `RowExclusiveLock`

```cpp
exec_simple_query
	start_xact_command
	    StartTransaction
		    GetNextLocalTransactionId
			VirtualXactLockTableInsert /* Take vxid lock via the fast-path */
	pg_analyze_and_rewrite_fixedparams
	    parse_analyze_fixedparams | transformTopLevelStmt | transformOptionalSelectInto
	        transformStmt | transformUpdateStmt
	            setTargetTable | parserOpenTable(pstate, relation, RowExclusiveLock)
	                table_openrv_extended | relation_openrv_extended | RangeVarGetRelidExtended
	                    LockRelationOid /* Lock a relation given only its OID */
	PortalRun | PortalRunMulti | ProcessQuery
		ExecutorRun | standard_ExecutorRun | ExecutePlan | ...
			heap_update
				GetCurrentTransactionId | AssignTransactionId
					XactLockTableInsert
						LockAcquire /* sleep if conflict found, set lock if/when no conflicts.*/
							LockAcquireExtended
								partitionLock = LockHashPartitionLock(hashcode);
								LWLockAcquire(partitionLock, LW_EXCLUSIVE);
								proclock = SetupLockInTable
								LockCheckConflicts
								GrantLock(lock, proclock, lockmode);
								GrantLockLocal(locallock, owner);
								LWLockRelease(partitionLock);
								return LOCKACQUIRE_OK;
				HeapTupleSatisfiesUpdate
				compute_new_xmax_infomask
				CheckForSerializableConflictIn
				
				START_CRIT_SECTION();
				
				PageSetPrunable(page, xid);
				HeapTupleSetHotUpdated(&oldtup); /* Mark the old tuple as HOT-updated */
				HeapTupleSetHeapOnly(heaptup); /* And mark the new tuple as heap-only */
				HeapTupleSetHeapOnly(newtup); /* Mark the caller's copy too, in case different from heaptup */
				RelationPutHeapTuple
				
				oldtup.t_data->t_ctid = heaptup->t_self; /* record address of new tuple in t_ctid of old one */
				MarkBufferDirty(buffer);
				
				/* XLOG stuff */
				log_heap_update
				PageSetLSN
				
				END_CRIT_SECTION();
				
				return TM_Ok;
	finish_xact_command
		CommitTransactionCommand
			CommitTransaction
				ResourceOwnerRelease
					ResourceOwnerReleaseInternal
						ProcReleaseLocks
							LockReleaseAll
								VirtualXactLockTableCleanup
```