# TransState 与 TBlockState 的关系

## 简要定义

### TransState（事务状态）

```c
/*
 *	transaction states - transaction state from server perspective
 */
typedef enum TransState
{
	TRANS_DEFAULT,				/* idle */
	TRANS_START,				/* transaction starting */
	TRANS_INPROGRESS,			/* inside a valid transaction */
	TRANS_COMMIT,				/* commit in progress */
	TRANS_ABORT,				/* abort in progress */
	TRANS_PREPARE				/* prepare in progress */
} TransState;
```

**作用：** 描述**事务本身的执行状态**，从服务器内核角度反映事务进度。

---

### TBlockState（事务块状态）

```c
/*
 *	transaction block states - transaction state of client queries
 *
 * Note: the subtransaction states are used only for non-topmost
 * transactions; the others appear only in the topmost transaction.
 */
typedef enum TBlockState
{
	/* not-in-transaction-block states */
	TBLOCK_DEFAULT,				/* idle */
	TBLOCK_STARTED,				/* running single-query transaction */

	/* transaction block states */
	TBLOCK_BEGIN,				/* starting transaction block */
	TBLOCK_INPROGRESS,			/* live transaction */
	TBLOCK_IMPLICIT_INPROGRESS, /* live transaction after implicit BEGIN */
	TBLOCK_PARALLEL_INPROGRESS, /* live transaction inside parallel worker */
	TBLOCK_END,					/* COMMIT received */
	TBLOCK_ABORT,				/* failed xact, awaiting ROLLBACK */
	TBLOCK_ABORT_END,			/* failed xact, ROLLBACK received */
	TBLOCK_ABORT_PENDING,		/* live xact, ROLLBACK received */
	TBLOCK_PREPARE,				/* live xact, PREPARE received */

	/* subtransaction states */
	TBLOCK_SUBBEGIN,			/* starting a subtransaction */
	TBLOCK_SUBINPROGRESS,		/* live subtransaction */
	TBLOCK_SUBRELEASE,			/* RELEASE received */
	TBLOCK_SUBCOMMIT,			/* COMMIT received while TBLOCK_SUBINPROGRESS */
	TBLOCK_SUBABORT,			/* failed subxact, awaiting ROLLBACK */
	TBLOCK_SUBABORT_END,		/* failed subxact, ROLLBACK received */
	TBLOCK_SUBABORT_PENDING,	/* live subxact, ROLLBACK received */
	TBLOCK_SUBRESTART,			/* live subxact, ROLLBACK TO received */
	TBLOCK_SUBABORT_RESTART		/* failed subxact, ROLLBACK TO received */
} TBlockState;
```

**作用：** 描述**事务块的控制流状态**，从SQL语法层面反映用户命令执行流程。

---

## 两者的关系

```
┌─────────────────────────────────────┐
│  BEGIN; INSERT; COMMIT;             │
└─────────────────────────────────────┘
           ↓
┌─────────────────────────────────────┐
│ TBlockState (SQL)                   │
│ ├─ TBLOCK_DEFAULT                   │
│ ├─ TBLOCK_BEGIN (BEGIN)             │
│ ├─ TBLOCK_INPROGRESS (INSERT)       │
│ └─ TBLOCK_END (COMMIT)              │
└─────────────────────────────────────┘
           ↓
┌─────────────────────────────────────┐
│ TransState (SERVER)                 │
│ ├─ TRANS_DEFAULT                    │
│ ├─ TRANS_START (BEGIN)              │
│ ├─ TRANS_INPROGRESS (INSERT)        │
│ └─ TRANS_COMMIT (COMMIT)            │
└─────────────────────────────────────┘
```

---

## 层次划分

| 层级       | 状态        | 职责                                | 视角         |
| ---------- | ----------- | ----------------------------------- | ------------ |
| **SQL 层** | TBlockState | 处理 BEGIN、COMMIT、ROLLBACK 等命令 | 用户命令流   |
| **内核层** | TransState  | 管理事务的实际执行进度              | 事务执行进度 |

---

## 对应关系示例

```
用户命令              TBlockState              TransState
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[初始状态]           TBLOCK_DEFAULT      ←→  TRANS_DEFAULT

BEGIN;               TBLOCK_BEGIN        ←→  TRANS_START

INSERT ...;          TBLOCK_INPROGRESS   ←→  TRANS_INPROGRESS

COMMIT;              TBLOCK_END          ←→  TRANS_COMMIT

[完成]               TBLOCK_DEFAULT      ←→  TRANS_DEFAULT
```

[draw_trans_state](assets/draw_trans_state.md)