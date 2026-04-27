# Lock conflict

```sql
begin;
select * from tb;
```

```sql
alter table tb add c int;
```

```text
exec_simple_query
    PortalRun | PortalRunMulti | PortalRunUtility | ProcessUtility
        standard_ProcessUtility | ProcessUtilitySlow
            AlterTableLookupRelation | RangeVarGetRelidExtended
                LockRelationOid | LockAcquireExtended | WaitOnLock
	                ProcSleep
	                    WaitLatch | WaitEventSetWait /* src/backend/storage/ipc/latch.c */
		                    WaitEventSetWaitBlock
```

```text
进程A（持锁）        进程B（请求锁）

LockAcquire
                     LockAcquire
                     → 冲突
                     → 加入 wait queue
                     → ProcSleep（睡眠）

LockRelease
→ ProcLockWakeup
→ SetLatch(B)

                     被唤醒
                     → 重新检查
                     → 获取锁成功
```


| PROC A (持有锁)                                       | PROC B(请求锁)                                              |
| -------------------------------------------------- | -------------------------------------------------------- |
| LockAcquire                                        |                                                          |
|                                                    | LockAcquire<br>-> 冲突<br>-> 加入 wait queue<br>-> ProcSleep |
| LockRelease<br>-> ProcLockWakeup<br>-> SetLatch(B) |                                                          |
|                                                    | 被唤醒<br>-> 重新检查<br>-> 获取锁                                 |
