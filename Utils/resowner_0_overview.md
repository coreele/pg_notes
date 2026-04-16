# ResourceOwner

ResourceOwner 用于“统一管理**非内存资源**生命周期”的机制，确保资源在事务/执行结束或异常时被正确释放（手动实现 **RAII** ）。

* 资源分散在各模块（buffer / lock / snapshot / file …）
* 执行中可能随时中断
* 需要统一兜底释放

## 核心设计

树结构（作用域）

```text
TopTransaction
  ├── SubTransaction
  └── Portal
```

分阶段释放(保证资源依赖顺序正确)

```text
BEFORE LOCKS → LOCKS → AFTER LOCKS
```

核心结构

```cpp

/*
 * ResourceOwner objects look like this
 */
typedef struct ResourceOwnerData
{
	ResourceOwner parent;		/* NULL if no parent (toplevel owner) */
	ResourceOwner firstchild;	/* head of linked list of children */
	ResourceOwner nextchild;	/* next child of same parent */
	const char *name;			/* name (just for debugging) */

	/* We have built-in support for remembering: */
	ResourceArray bufferarr;	/* owned buffers */
	ResourceArray bufferioarr;	/* in-progress buffer IO */
	ResourceArray catrefarr;	/* catcache references */
	ResourceArray catlistrefarr;	/* catcache-list pins */
	ResourceArray relrefarr;	/* relcache references */
	ResourceArray planrefarr;	/* plancache references */
	ResourceArray tupdescarr;	/* tupdesc references */
	ResourceArray snapshotarr;	/* snapshot references */
	ResourceArray filearr;		/* open temporary files */
	ResourceArray dsmarr;		/* dynamic shmem segments */
	ResourceArray jitarr;		/* JIT contexts */
	ResourceArray cryptohasharr;	/* cryptohash contexts */
	ResourceArray hmacarr;		/* HMAC contexts */

	/* We can remember up to MAX_RESOWNER_LOCKS references to local locks. */
	int			nlocks;			/* number of owned locks */
	LOCALLOCK  *locks[MAX_RESOWNER_LOCKS];	/* list of owned locks */
}			ResourceOwnerData;
```

核心接口

```cpp
ResourceOwnerCreate
ResourceOwnerRelease
ResourceOwnerDelete
ResourceOwnerRemember_____
ResourceOwnerForget_____
```


```sql
BEGIN;

INSERT INTO t VALUES (0);

SAVEPOINT sp1;
INSERT INTO t VALUES (1);
ROLLBACK TO sp1;


SAVEPOINT sp2;
INSERT INTO t VALUES (2);
COMMIT;
```
