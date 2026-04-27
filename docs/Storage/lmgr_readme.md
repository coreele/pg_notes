# Lock readme

锁概述

Postgres 使用四种类型的进程间锁：

- **自旋锁 (Spinlocks)。** 这类锁旨在用于*极*短期的锁定。如果锁需要持有超过几十条指令的时间，或者跨越任何类型的内核调用（甚至是调用一个非平凡的子程序），请不要使用自旋锁。自旋锁主要用作轻量级锁的基础设施。如果可用，它们是使用硬件原子测试并设置 (atomic-test-and-set) 指令实现的。等待的进程会进行忙循环 (busy-loop)，直到它们获取到锁。不提供死锁检测、出错时自动释放或任何其他便利功能。如果在一分钟左右无法获取锁，会有超时机制（相对于预期的锁持有时间，这大约是永远，因此这肯定是一个错误条件）。

- **轻量级锁 (Lightweight locks, LWLocks)。** 这些锁通常用于互锁访问共享内存中的数据结构。LWLock 支持排他和共享两种锁模式（用于共享对象的读/写和只读访问）。不提供死锁检测，但 LWLock 管理器会在 `elog()` 恢复期间自动释放已持有的 LWLock，因此在持有 LWLock 时抛出错误是安全的。当没有锁竞争时，获取或释放 LWLock 非常快（几十条指令）。当进程必须等待 LWLock 时，它会阻塞在 SysV 信号量上，以便不消耗 CPU 时间。等待的进程将按到达顺序被授予锁。没有超时机制。

- **常规锁 (Regular locks)（又称重量级锁 heavyweight locks）。** 常规锁管理器支持多种锁模式，具有表驱动 (table-driven) 语义，并且拥有完整的死锁检测和事务结束时自动释放的功能。所有用户驱动的锁请求都应使用常规锁。

- **SIReadLock 谓词锁 (predicate locks)。** 详情请参见单独的 README-SSI 文件。

获取自旋锁或轻量级锁会导致查询取消 (query cancel) 和 `die()` 中断被挂起 (held off)，直到所有此类锁被释放。然而，常规锁不存在此类限制。另外请注意，我们在等待常规锁时可以接受查询取消和 `die()` 中断，但在等待自旋锁或 LW 锁时不会接受它们。因此，当等待时间可能超过几秒钟时，使用 LW 锁并不是一个好主意。

本 README 文件的其余部分将详细讨论常规锁管理器。

## 锁数据结构

**锁方法 (Lock methods)** 描述了整体的锁定行为。目前有两种锁方法：`DEFAULT`（默认）和 `USER`（用户）。

**锁模式 (Lock modes)** 描述了锁的类型（读/写 或 共享/排他）。原则上，每种锁方法都可以拥有自己的一套锁模式及不同的冲突规则，但目前 `DEFAULT` 和 `USER` 方法使用的是完全相同的锁模式集合。有关更多细节，请参阅 `src/include/storage/lock.h`。（在代码和文档的某些地方，锁模式也被称为锁类型。）

在共享内存中记录锁主要有两种机制：

1.  **主要机制**使用两个核心结构体：
    - **`LOCK` 结构体**：针对每个可锁定对象（per-lockable-object）。只要某个可锁定对象当前有被持有或被请求的锁，就会存在一个对应的 `LOCK` 对象。
    - **`PROCLOCK` 结构体**：针对每个后端进程与每个 `LOCK` 对象之间的锁定关系（per-lock-and-requestor）。如果一个后端进程正在持有或请求某个 `LOCK` 对象上的锁，就会存在一个对应的 `PROCLOCK` 结构体。

2.  **特殊的“快速路径” (fast path) 机制**：后端进程可以使用此机制来记录数量有限且具有非常特定特征的锁。这些锁必须满足以下条件：
    - 必须使用 `DEFAULT` 锁方法；
    - 必须代表对数据库关系（**relation**）的锁（不能是共享关系）；
    - **必须是“弱”锁**，即不太可能发生冲突的锁（具体指 `AccessShareLock`、`RowShareLock` 或 `RowExclusiveLock`）；
    - 系统必须能够快速验证不可能存在任何冲突的锁。
      有关更多细节，请参阅下文的“快速路径锁定 (Fast Path Locking)"。

此外，每个后端进程还会为它当前正在持有或请求的每个可锁定对象及锁模式，维护一个**非共享的 `LOCALLOCK` 结构体**。
共享锁结构体仅允许针对每个“可锁定对象/锁模式/后端进程”组合进行**一次**锁授予。然而，在后端进程内部，同一个锁可能在事务中被多次请求甚至释放，也可以同时以事务级和会话级的方式持有。内部的**请求计数**保存在 `LOCALLOCK` 中，这样就不需要访问共享数据结构来修改它们了。
### LOCK

```cpp
typedef struct LOCK
{
	/* hash key */
	LOCKTAG		tag;			/* unique identifier of lockable object */

	/* data */
	LOCKMASK	grantMask;		/* bitmask for lock types already granted */
	LOCKMASK	waitMask;		/* bitmask for lock types awaited */
	dlist_head	procLocks;		/* list of PROCLOCK objects assoc. with lock */
	dclist_head waitProcs;		/* list of PGPROC objects waiting on lock */
	int			requested[MAX_LOCKMODES];	/* counts of requested locks */
	int			nRequested;		/* total of requested[] array */
	int			granted[MAX_LOCKMODES]; /* counts of granted locks */
	int			nGranted;		/* total of granted[] array */
} LOCK;
```

锁管理器的 **`LOCK` 对象**包含以下字段：

- **`tag` (标签)**
  - 这是用于在共享内存锁哈希表中对锁进行哈希处理的关键字段。`tag` 的内容本质上**定义了一个独立的可锁定对象**。
  - 关于支持的可锁定对象类型的详细信息，请参阅 `include/storage/lock.h`。
  - 它被声明为一个单独的结构体，以确保我们总是能清零正确数量的字节。**至关重要**的是，编译器可能在结构体中插入的任何对齐填充字节（alignment-padding bytes）都必须被清零，否则哈希计算将是随机的。（目前，我们小心翼翼地定义 `struct LOCKTAG`，以确保其中没有填充字节。）

- **`grantMask` (授予掩码)**
  - 这是一个位掩码 (bitmask)，指示当前在该可锁定对象上持有哪些类型的锁。
  - 它用于（结合锁表的冲突表）确定新的锁请求是否会与现有的已持有锁类型发生冲突。
  - 冲突是通过将 `grantMask` 与所请求锁类型对应的冲突表条目进行**按位与 (bitwise AND)** 操作来确定的。
  - 当且仅当 `granted[i] > 0` 时，`grantMask` 的第 `i` 位为 1。

- **`waitMask` (等待掩码)**
  - 这是一个位掩码，显示当前正在等待哪些类型的锁。
  - 当且仅当 `requested[i] > granted[i]` 时，`waitMask` 的第 `i` 位为 1。

- **`procLocks` (进程锁链表)**
  - 这是一个位于**共享内存**中的队列，包含与该锁对象关联的所有 `PROCLOCK` 结构体。
  - 请注意，**已授予**和**正在等待**的 `PROCLOCK` 都在这个列表中（事实上，同一个 `PROCLOCK` 可能已经持有一些已授予的锁，同时还在等待更多的锁！）。

- **`waitProcs` (等待进程队列)**
  - 这是一个位于共享内存中的队列，包含所有因等待其他后端释放此锁而处于等待（睡眠）状态的 `PGPROC` 结构体（对应后端进程）。
  - 进程结构体中持有必要的信息，用于确定当锁被释放时是否应该唤醒该进程。

- **`nRequested` (总请求次数)**
  - 记录尝试获取此锁的总次数。
  - 该计数包括那些因冲突而被放入睡眠状态的进程的尝试。
  - 如果同一个后端进程先获取了读锁，然后又获取了写锁，它会被计数两次。
  - （但是，同一个后端进程内部对同一锁/同一模式的多次获取不会在此处重复计数；这些记录仅保存在后端的 `LOCALLOCK` 结构体中。）

- **`requested` (各模式请求计数数组)**
  - 记录每种类型的锁被尝试请求的次数。
  - 仅使用索引 `1` 到 `MAX_LOCKMODES-1` 的元素，因为它们对应于定义的锁类型常量（索引 0 不使用）。
  - 对 `requested[]` 数组中的所有值求和，结果应等于 `nRequested`。

- **`nGranted` (总授予次数)**
  - 记录成功获取此锁的总次数。
  - 该计数**不**包括因冲突而正在等待的尝试。
  - 其他的计数规则与 `nRequested` 相同。

- **`granted` (各模式授予计数数组)**
  - 记录当前持有的每种类型的锁的数量。
  - 同样，仅使用索引 `1` 到 `MAX_LOCKMODES-1` 的元素（0 不使用）。
  - 与 `requested[]` 类似，对 `granted[]` 数组中的所有值求和，结果应等于 `nGranted`。

**不变式约束：**
我们必须始终满足：

- `0 <= nGranted <= nRequested`
- 对于每个 `i`，`0 <= granted[i] <= requested[i]`

当所有请求计数归零时，`LOCK` 对象不再需要，可以被释放。

### PROCLOCK

锁管理器的 **`PROCLOCK` 对象**包含以下字段：

- **`tag` (标签)**
  - 这是用于在共享内存 `PROCLOCK` 哈希表中对条目进行哈希处理的关键字段。
  - 它被声明为一个单独的结构体，以确保我们总是能清零正确数量的字节。**至关重要**的是，编译器可能在结构体中插入的任何对齐填充字节（alignment-padding bytes）都必须被清零，否则哈希计算将是随机的。（目前，我们小心翼翼地定义 `struct PROCLOCKTAG`，以确保其中没有填充字节。）
  - **`tag.myLock`**: 指向此 `PROCLOCK` 所对应的共享 `LOCK` 对象的指针。
  - **`tag.myProc`**: 指向拥有此 `PROCLOCK` 的后端进程的 `PGPROC` 结构的指针。
  - **注意**：在这里使用指针是安全的，因为 `PROCLOCK` 的生命周期绝不会超过其关联的锁（`LOCK`）或其关联的进程（`PGPROC`）。因此，只要该 `PROCLOCK` 存在，这个标签就是唯一的，即使相同的指针值在其他时间点可能代表完全不同的含义（即内存复用后）。

- **`holdMask` (持有掩码)**
  - 这是一个位掩码，表示此 `PROCLOCK` **成功获取**的锁模式。
  - 它应该是 `LOCK` 对象的 `grantMask` 的子集。
  - 同时，如果该 `PGPROC` 正在等待同一锁对象上的其他模式锁，它也应该是 `PGPROC` 对象的 `heldLocks` 掩码的子集。
  - _通俗理解_：这就是该进程当前“手里实实在在拿着”的锁有哪些。

- **`releaseMask` (释放掩码)**
  - 这是一个位掩码，表示在调用 `LockReleaseAll` 时**即将被释放**的锁模式。
  - 它必须是 `holdMask` 的子集（你只能释放你持有的锁）。
  - **重要并发细节**：这个字段的修改**不需要**获取分区的 LWLock（轻量级锁）。因此，除了拥有此 `PROCLOCK` 的那个后端进程本身外，**任何其他后端进程检查或修改此字段都是不安全的**。
  - _设计意图_：这是一种优化。当事务结束需要批量释放所有锁时， owning backend 可以独自快速标记哪些锁要放掉，而无需争抢全局锁，从而提高事务提交/回滚的性能。

- **`lockLink` (锁链表链接)**
  - 这是用于将所有属于**同一个 `LOCK` 对象**的 `PROCLOCK` 对象链接起来的列表指针。
  - 通过它，可以从 `LOCK` 对象找到所有对该对象感兴趣（持有或等待）的进程（即前文提到的 `procLocks` 队列）。

- **`procLink` (进程链表链接)**
  - 这是用于将所有属于**同一个后端进程**的 `PROCLOCK` 对象链接起来的列表指针。
  - 通过它，可以从 `PGPROC`（进程结构）快速找到该进程当前参与的所有锁对象。这对于事务结束时快速遍历并释放该进程持有的所有锁非常关键。

### 核心要点总结

1.  **唯一性由指针保证**：`tag` 直接存储 `LOCK*` 和 `PGPROC*` 指针。因为 PG 的内存管理保证了只要 `PROCLOCK` 活着，它指向的锁和进程就一定活着，所以不用担心悬空指针问题。这也避免了在 tag 中存储复杂的 ID 映射，提升了查找速度。
2.  **双重链表归属**：
    - `lockLink` 让 `PROCLOCK` 挂在 **锁** 的维度上（方便锁管理器看谁在等这个锁）。
    - `procLink` 让 `PROCLOCK` 挂在 **进程** 的维度上（方便进程看自己持有了哪些锁，或在退出时清理）。
    - 这使得 `PROCLOCK` 成为连接“资源”与“请求者”的完美桥梁。
3.  **无锁优化 (`releaseMask`)**：`releaseMask` 的设计体现了高性能数据库的典型特征——在能保证正确性的前提下（只有所有者能改），尽可能减少锁竞争，让事务清理阶段更快。

```
[LOCK: Table A] 
    |
    +-- procLocks (链表) --> [PROCLOCK: Proc 1 & Table A] --> [PROCLOCK: Proc 2 & Table A] --> ...
    |                             |                               |
    |                             v                               v
    |                        (指向 Proc 1)                     (指向 Proc 2)
    |
    +-- waitProcs (队列) --> [PGPROC: Proc 2] (如果在睡)
```

```
[PGPROC: Current Backend]
    |
    +-- myProcLocks[0] --> [PROCLOCK: Me & Lock X] --> [PROCLOCK: Me & Lock Y]
    |                           |                          |
    |                           v                          v
    |                      (指向 LOCK X)              (指向 LOCK Y)
    |
    +-- myProcLocks[1] --> [PROCLOCK: Me & Lock Z]
    |                           |
    |                           v
    |                      (指向 LOCK Z)
    ...
    +-- myProcLocks[N] --> (空)
```

### 保存位置

```cpp
/*
 * Pointers to hash tables containing lock state
 *
 * The LockMethodLockHash and LockMethodProcLockHash hash tables are in
 * shared memory; LockMethodLocalHash is local to each backend.
 */
static HTAB *LockMethodLockHash;
static HTAB *LockMethodProcLockHash;
static HTAB *LockMethodLocalHash;
```

[draw_proclock](assets/draw_proclock.md)
## 锁管理器内部锁定机制

在 PostgreSQL 8.2 之前，锁管理器使用的所有共享内存数据结构都由**单个**轻量级锁（LWLock）—— `LockMgrLock` 进行保护；任何涉及这些数据结构的操作都必须独占性地锁定 `LockMgrLock`。不出所料，这成为了一个竞争瓶颈。

为了减少竞争，锁管理器的数据结构已被拆分为多个"**分区 (partitions)**"，每个分区由一个独立的 LWLock 保护。大多数操作只需要锁定它们正在操作的那个单一分区即可。具体细节如下：

- **锁的分区分配**：每个可能的锁根据其 `LOCKTAG` 值的哈希结果被分配到一个特定的分区。该分区的 LWLock 被认为保护了该分区内的所有 `LOCK` 对象及其附属的 `PROCLOCK` 对象。

- **哈希表的分区组织**：
  - 用于 `LOCK` 和 `PROCLOCK` 的共享内存哈希表经过组织，使得不同的分区使用不同的哈希链。因此，操作不同分区中的对象时不会产生冲突。
  - 对于 `LOCK` 表，这直接由 `dynahash.c` 的“分区表”机制支持：我们只需确保分区号取自 `LOCKTAG` 的 `dynahash` 哈希值的**低位比特**。
  - 为了让这对 `PROCLOCK` 也生效，我们必须确保 `PROCLOCK` 的哈希值与其关联的 `LOCK` 具有相同的**低位比特**。这需要专门的哈希函数（参见 `proclock_hash`）。

- **PGPROC 列表的分区化**：
  - 以前，每个 `PGPROC`（进程结构）只有一个属于它的 `PROCLOCK` 列表。
  - 现在，这已被拆分为**每个分区一个列表**。这样，访问特定的 `PROCLOCK` 列表就可以由相关联分区的 LWLock 来保护。
  - （这条规则允许一个后端进程操作另一个后端进程的 `PROCLOCK` 列表。这在最初并非必要，但现在为了配合“快速路径锁定 (fast-path locking)"已成为必需；详见下文。）

- **PGPROC 其他字段的保护**：`PGPROC` 中其他与锁相关的字段仅在该 `PGPROC` 等待锁时才相关，因此我们认为它们由**所等待锁所在分区**的 LWLock 保护。

### 处理锁请求函数签名

```cpp
/*
 * Find or create LOCK and PROCLOCK objects as needed for a new lock
 * request.
 *
 * Returns the PROCLOCK object, or NULL if we failed to create the objects
 * for lack of shared memory.
 *
 * The appropriate partition lock must be held at entry, and will be
 * held at exit.
 */
static PROCLOCK *
SetupLockInTable(LockMethod lockMethodTable, PGPROC *proc,
				 const LOCKTAG *locktag, uint32 hashcode, LOCKMODE lockmode);
```

**关于正常操作与死锁检测：**

- **正常的锁获取与释放**：只需锁定包含目标锁的那个分区就足够了。
- **死锁检测**：通常需要接触多个分区。为了简化实现，我们让其按**分区编号顺序**锁定所有分区。
  - **防止 LWLock 死锁的规则**：任何需要同时锁定多个分区的后端进程，**必须**按分区编号升序依次锁定它们。
  - 虽然在典型情况下，死锁检测可能无需触碰每一个分区就能完成，但在一个运行正常的系统中，死锁检测不应频繁到成为性能关键点的程度。因此，试图优化这一点似乎并不是高效利用开发精力的做法。

**关于 LOCALLOCK：**

- 后端的内部 `LOCALLOCK` 哈希表**没有**进行分区。
- 我们在 `LOCALLOCK` 表条目中存储了锁标签（locktag）哈希码的副本，从中可以计算出分区号。
- 这是一种典型的**空间换时间 (speed-for-space)** 的权衡：我们也可以选择在需要时从 `LOCKTAG` 重新计算分区号，但存储副本可以避免重复计算，提升速度。

## 快速路径锁定 (Fast Path Locking)

快速路径锁定是一种专用机制，旨在降低获取和释放某些特定类型锁的开销。这些锁的特点是：**被频繁地获取和释放，但极少发生冲突**。目前，该机制主要涵盖两类锁：

1.  **弱关系锁 (Weak relation locks)**：
    - `SELECT`、`INSERT`、`UPDATE` 和 `DELETE` 操作必须获取它们所操作的每个关系（表）以及各种内部使用的系统目录的锁。
    - 许多 DML 操作可以针对同一张表并行执行；只有 DDL 操作（如 `CLUSTER`、`ALTER TABLE` 或 `DROP`）或用户的显式操作（如 `LOCK TABLE`）才会与 DML 操作获取的“弱”锁（即 `AccessShareLock`、`RowShareLock`、`RowExclusiveLock`）产生冲突。

2.  **VXID 锁 (虚拟事务 ID 锁)**：
    - 每个事务都会获取其自身虚拟事务 ID (VXID) 的锁。
    - 目前，只有 `CREATE INDEX CONCURRENTLY` 和热备 (Hot Standby，在发生冲突时) 等操作会等待这些锁。因此，大多数 VXID 锁由其所有者获取和释放，无需其他进程关心。

**主要问题：**
主要的锁机制无法很好地应对这种工作负载。即使锁管理器的锁已经进行了分区，任何给定关系的锁标签 (locktag) 仍然只落在**一个且唯一一个**分区中。因此，如果许多短查询同时访问同一个关系，该分区的锁管理器分区锁就会成为竞争瓶颈。这种效应在双核服务器上就已经可测量，并且随着核心数量的增加而变得非常显著。

**解决方案：**
为了缓解这一瓶颈，从 PostgreSQL 9.2 开始，允许每个后端进程在其 `PGPROC` 结构内的一个数组中记录有限数量的**非共享关系**上的锁，而不是使用主锁表。

- **使用条件**：仅当加锁者能够验证在获取锁的时刻**不存在任何冲突锁**时，才能使用此机制。

**核心算法逻辑：**
该算法的关键点在于：必须能够在**不争抢共享 LWLock 或自旋锁**的情况下，验证是否存在潜在的冲突锁。否则，这只是将竞争瓶颈从一个地方转移到了另一个地方，毫无意义。

我们如何实现这一点？

- 我们使用了一个包含 **1024 个整数计数器**的数组 (`FastPathStrongRelationLocks`)。这实际上是将锁空间进行了 **1024 路分区**。
- 每个计数器记录了落入该分区的非共享关系上的"**强**"锁（即 `ShareLock`、`ShareRowExclusiveLock`、`ExclusiveLock` 和 `AccessExclusiveLock`）的数量。
- **规则**：当某个计数器**非零**时，禁止在该分区内使用快速路径机制来获取新的关系锁。
- **强锁获取流程**：
  1.  想要获取强锁的进程首先将该计数器加 1 ("bump the counter")。
  2.  然后扫描**每个后端进程**的快速路径数组，查找匹配的快速路径锁。
  3.  如果发现任何匹配项，必须在尝试获取锁之前，将这些锁**转移 (transfer)** 到主锁表中。这是为了确保正确的锁冲突检测和死锁检测。

**内存同步 (SMP 系统)：**
在多处理器 (SMP) 系统上，我们必须保证适当的内存同步。这里我们依赖一个事实：**LWLock 的获取充当了内存序列点 (memory sequence point)**。

- **原理**：如果进程 A 执行了存储操作，随后进程 A 和 B 以任意顺序获取了同一个 LWLock，接着进程 B 对同一内存位置执行加载操作，那么 B 保证能看到 A 的存储结果。
- **应用**：
  - 每个后端的快速路径锁队列都由一个 LWLock 保护。
  - **想获取快速路径锁的后端**：在检查 `FastPathStrongRelationLocks` 以确认是否存在冲突的强锁之前，必须先获取这个 LWLock。
  - **想获取强锁的后端**：由于它必须将所有通过快速路径获取的匹配弱锁转移到共享锁表，因此它将依次获取**每一个**保护后端快速路径队列的 LWLock。
  - **结论**：如果我们检查 `FastPathStrongRelationLocks` 发现值为 0，那么要么该值确实为 0；要么它是一个过时的值，但在这种情况下，获取强锁的进程尚未获取到我们当前持有的那个后端 LWLock（甚至可能是第一个后端 LWLock）。一旦它获取到该锁，它就会注意到我们刚刚获取的任何弱锁。

**关于 VXID 锁的特殊处理：**

- 快速路径 VXID 锁**不使用** `FastPathStrongRelationLocks` 表。
- VXID 上的第一个锁始终是其所有者获取的 `ExclusiveLock`。
- 任何后续的加锁者都是等待 VXID 结束的共享锁持有者。
- 事实上，VXID 锁之所以使用锁管理器（而不是通过其他方式等待 VXID 结束），唯一的原因是为了**死锁检测**。
- 因此，初始的 VXID 锁**总是**可以通过快速路径获取，**无需检查冲突**。
- 任何后续的加锁者必须检查该锁是否已被转移到主锁表；如果没有，则执行转移操作。
- 拥有 VXID 的后端必须在事务结束时小心清理主锁表中的任何条目。

**死锁检测：**
死锁检测**不需要**检查快速路径数据结构，因为任何可能卷入死锁的锁，在此之前都必然已经被转移到了主表中。

The Deadlock Detection Algorithm
--------------------------------
Miscellaneous Notes
-------------------
Group Locking
-------------
User Locks (Advisory Locks)
---------------------------
Locking during Hot Standby
--------------------------
