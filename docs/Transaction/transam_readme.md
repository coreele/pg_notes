src/backend/access/transam/README

# 事务系统

PostgreSQL 的事务系统是一个三层系统。底层实现低级事务和子事务，其上构建主循环的控制代码，进而实现用户可见的事务和保存点。

中间层代码在 postgres.c 中被调用，在每个查询处理前后，或在检测到错误后调用：

    	StartTransactionCommand
    	CommitTransactionCommand
    	AbortCurrentTransaction

同时，用户可以通过发出 SQL 命令 BEGIN、COMMIT、ROLLBACK、SAVEPOINT、ROLLBACK TO 或 RELEASE 来改变系统状态。流量控制器将这些调用重定向到顶层例程：

    	BeginTransactionBlock
    	EndTransactionBlock
    	UserAbortTransactionBlock
    	DefineSavepoint
    	RollbackToSavepoint
    	ReleaseSavepoint

根据系统的当前状态，这些函数调用低级函数来激活真正的事务系统：

    	StartTransaction
    	CommitTransaction
    	AbortTransaction
    	CleanupTransaction
    	StartSubTransaction
    	CommitSubTransaction
    	AbortSubTransaction
    	CleanupSubTransaction

此外，在事务内部，CommandCounterIncrement 被调用来递增命令计数器，这使得后续命令能够"看到"同一事务中先前命令的效果。注意，这在事务块内的每个查询之后由 CommitTransactionCommand 自动完成，但某些实用函数也在内部执行此操作，以允许同一实用命令中的后续操作看到某些操作（通常在系统目录中）的效果。（例如，在 DefineRelation 中，它在创建堆表之后执行，使 pg_class 行可见，以便能够锁定它。）

例如，考虑以下用户命令序列：

```
1.      BEGIN
2.      SELECT * FROM foo
3.      INSERT INTO foo VALUES (...)
4.      COMMIT
```

在主处理循环中，这导致以下函数调用序列：

```
     /  StartTransactionCommand;
    /       StartTransaction;
1) <    ProcessUtility;                 << BEGIN
    \       BeginTransactionBlock;
     \  CommitTransactionCommand;

    /   StartTransactionCommand;
2) /    PortalRunSelect;                << SELECT ...
   \    CommitTransactionCommand;
    \       CommandCounterIncrement;

    /   StartTransactionCommand;
3) /    ProcessQuery;                   << INSERT ...
   \    CommitTransactionCommand;
    \       CommandCounterIncrement;

     /  StartTransactionCommand;
    /   ProcessUtility;                 << COMMIT
4) <        EndTransactionBlock;
    \   CommitTransactionCommand;
     \      CommitTransaction;
```

这个例子的重点在于展示 StartTransactionCommand 和 CommitTransactionCommand 需要具备状态感知能力——它们应该在 BeginTransactionBlock 和 EndTransactionBlock 调用之间调用 CommandCounterIncrement，而在这些调用之外则需要执行正常的启动、提交或中止处理。

此外，假设 "SELECT \* FROM foo" 导致了中止条件。在这种情况下会调用 AbortCurrentTransaction，事务被置于中止状态。在此状态下，除了事务终止语句或 ROLLBACK TO <savepoint> 命令外，任何用户输入都将被忽略。

事务中止可以通过两种方式发生：

1. 系统因某些内部原因而中止（语法错误等）
2. 用户输入 ROLLBACK

我们必须区分它们的原因通过以下两种情况来说明：

```
        case 1                                  case 2
        ------                                  ------
1) user types BEGIN                     1) user types BEGIN
2) user does something                  2) user does something
3) user does not like what              3) system aborts for some reason
   she sees and types ABORT                (syntax error, etc)
```

在情况 1 中，我们希望中止事务并返回到默认状态。在情况 2 中，可能会有更多属于同一事务块的命令到来；我们必须忽略这些命令，直到看到 COMMIT 或 ROLLBACK。

内部中止由 AbortCurrentTransaction 处理，而用户中止由 UserAbortTransactionBlock 处理。两者都依赖 AbortTransaction 来完成所有实际工作。唯一的区别是 AbortTransaction 完成工作后我们进入什么状态：

- AbortCurrentTransaction 使我们处于 TBLOCK_ABORT 状态，
- UserAbortTransactionBlock 使我们处于 TBLOCK_ABORT_END 状态

低级事务中止处理分为两个阶段：

- AbortTransaction 在我们意识到事务失败后立即执行。它应该释放所有共享资源（锁等），以免不必要地延迟其他后端进程。
- CleanupTransaction 在我们最终看到用户 COMMIT 或 ROLLBACK 命令时执行；它清理所有内容并使我们完全退出事务。特别是，在此之前我们不能销毁 TopTransactionContext。

另外，请注意，当事务提交时，我们不会立即关闭它。而是将其置于 TBLOCK_END 状态，这意味着当查询处理完成后调用 CommitTransactionCommand 时，事务必须被关闭。这种区别很微妙但很重要，因为它意味着控制权将带着打开的事务离开 xact.c 代码，主循环将能够在同一事务内继续处理。因此，从某种意义上说，事务提交也分两个阶段处理，第一个阶段在 EndTransactionBlock，第二个阶段在 CommitTransactionCommand（这里实际调用 CommitTransaction）。

xact.c 中的其余代码是支持创建和完成事务及子事务的例程。例如，AtStart_Memory 负责在主事务启动时初始化内存子系统。

## 子事务处理

子事务使用 TransactionState 结构栈来实现，每个结构都有一个指向其父事务结构的指针。当要打开新的子事务时，调用 PushTransaction，它创建一个新的 TransactionState，其父链接指向当前事务。StartSubTransaction 负责将新的 TransactionState 初始化为合理的值，并正确初始化其他子系统（AtSubStart 例程）。

当关闭子事务时，要么调用 CommitSubTransaction（如果子事务正在提交），要么调用 AbortSubTransaction 和 CleanupSubTransaction（如果正在中止）。无论哪种情况，都会调用 PopTransaction，使系统返回到父事务。

关于子事务处理的一个重要点是，可能需要响应单个用户命令关闭多个子事务。这是因为保存点有名称，我们允许按名称提交或回滚保存点，而不一定是最后打开的那个。此外，COMMIT 或 ROLLBACK 命令必须能够关闭整个栈。我们通过让实用命令子程序将所有状态栈条目标记为待提交或待中止来处理这个问题，然后当主循环到达 CommitTransactionCommand 时，执行实际工作。这样做的主要优点是，如果在弹出状态栈条目时出现错误，剩余的栈条目仍然显示我们需要做什么来完成收尾工作。

在 ROLLBACK TO <savepoint> 的情况下，我们中止所有直到由保存点名称标识的子事务，然后用相同的名称重新创建该子事务级别。因此，就内部而言，这是一个全新的子事务。

其他子系统允许启动"内部"子事务，由 BeginInternalSubTransaction 处理。这是为了允许实现异常处理，例如在 PL/pgSQL 中。ReleaseCurrentSubTransaction 和 RollbackAndReleaseCurrentSubTransaction 允许子系统关闭所述子事务。这与保存点/释放路径的主要区别在于，我们在每个子程序中立即执行完整的状态转换，而不是将一些工作推迟到 CommitTransactionCommand。另一个区别是，当没有建立显式事务块时，允许 BeginInternalSubTransaction，而 DefineSavepoint 则不允许。

## 事务和子事务编号

事务和子事务只有在首次执行需要 XID 的操作时才会被分配永久 XID——通常是插入/更新/删除元组，尽管还有其他一些地方需要分配 XID。如果子事务需要 XID，我们总是先为其父事务分配一个。这保持了子事务的 XID 晚于其父事务的不变性，这在许多地方都有假设。

获取 XID 锁并将其输入 pg_subtrans 和 PGPROC 的辅助操作在分配时完成。

没有 XID 的事务仍需要出于各种目的进行标识，特别是持有锁。为此，我们为每个顶级事务分配一个"虚拟事务 ID"或 VXID。VXID 由两个字段组成：backendID 和后端本地计数器；这种安排允许在事务启动时分配新的 VXID，而不会对共享内存产生任何争用。为了确保 VXID 在后端退出后不会过早重用，我们在后端退出时将最后一个本地计数器值存储到共享内存中，并在后端启动时从同一 backendID 槽的前一个值初始化它。所有这些计数器在共享内存重新初始化时都会回到零，但这没关系，因为 VXID 永远不会出现在磁盘上的任何地方。

在内部，后端需要一种方法来标识子事务，无论它们是否有 XID；但这种需求仅在父顶级事务持续期间存在。因此，我们有 SubTransactionId，它有点像 CommandId，由一个计数器生成，我们在每个顶级事务开始时重置该计数器。顶级事务本身的 SubTransactionId 为 1，子事务的 ID 为 2 及以上。（零保留给 InvalidSubTransactionId。）注意，子事务没有自己的 VXID；它们使用父顶级事务的 VXID。

## 事务开始、事务结束和快照的互锁

我们努力最小化在频繁的开始/结束事务和获取快照活动中涉及的开销和锁争用。不幸的是，我们必须对此进行一些互锁，因为我们必须确保事务提交顺序的一致性。例如，假设事务 A 中的 UPDATE 被事务 B 先前对同一行的更新阻塞，而事务 B 正在提交，同时事务 C 获取快照。事务 A 可以在 B 释放其锁后立即完成并提交。如果事务 C 的 GetSnapshotData 看到事务 B 仍在运行，那么它最好也看到事务 A 仍在运行，否则它将能够看到两个元组版本——一个被事务 B 删除，一个被事务 A 插入。这不好的另一个原因是 C 会在（由 A 插入的行中）看到 B 的早期更改，而 C 在数据库的其他地方看不到 B 的任何更改是不一致的。

正式地说，正确性要求是"如果快照 A 认为事务 X 已提交，并且事务 X 的任何快照认为事务 Y 已提交，那么快照 A 必须认为事务 Y 已提交"。

我们实际强制执行的是提交和回滚与快照获取的严格序列化：在获取快照时，我们不允许任何事务退出正在运行的事务集。（这条规则比一致性所需的更强，但相对容易执行，并且有助于下面解释的其他一些问题。）其实现方式是 GetSnapshotData 以共享模式获取 ProcArrayLock（以便多个后端可以并行获取快照），但 ProcArrayEndTransaction 必须在事务结束时（提交或中止）清除 ProcGlobal->xids[] 条目时以独占模式获取 ProcArrayLock。（为了减少上下文切换，当多个事务几乎同时提交时，我们让一个后端获取 ProcArrayLock 并一次性清除多个进程的 XID。）

ProcArrayEndTransaction 在推进共享的 latestCompletedXid 变量时也持有锁。这允许 GetSnapshotData 使用 latestCompletedXid + 1 作为其快照的 xmax：不可能有需要快照视为已完成的大于或等于此 xid 值的事务。

简而言之，规则是在我们获取 latestCompletedXid 和我们完成构建快照之间的时间内，任何事务都不能退出当前运行的事务集。但是，此限制仅适用于具有 XID 的事务——只读事务可以在不获取 ProcArrayLock 的情况下结束，因为它们不影响其他人的快照或 latestCompletedXid。

事务启动本身与这些考虑没有任何互锁，因为我们不再在事务启动时立即分配 XID。但是当我们决定分配 XID 时，GetNewTransactionId 必须在释放 XidGenLock 之前将新 XID 存储到共享 ProcArray 中。这确保所有小于或等于 latestCompletedXid 的顶级 XID 要么存在于 ProcArray 中，要么不再运行。（此保证不适用于子事务 XID，因为 subxid 数组中可能没有足够的空间容纳它们；相反，我们保证它们存在或设置了溢出标志。）如果后端在将其 XID 存储到 ProcGlobal->xids[] 之前释放了 XidGenLock，那么另一个后端可能会分配并提交一个更晚的 XID，导致 latestCompletedXid 超过第一个后端的 XID，而该值尚未在 ProcArray 中可见。这将破坏 ComputeXidHorizons，如下文所述。

我们允许 GetNewTransactionId 在不获取 ProcArrayLock 的情况下将 XID 存储到 ProcGlobal->xids[]（或 subxid 数组）中。这曾经对于避免死锁是必要的；虽然情况已不再如此，但它仍然有利于性能。因此，我们依赖于 XID 的获取/存储是原子的，否则其他后端可能会看到部分设置的 XID。这也意味着 ProcArray xid 字段的读取者必须小心只获取一次值，而不是假设他们可以多次读取它并每次都得到相同的答案。（在执行此操作时使用 volatile 限定的指针，以确保 C 编译器完全按照您的指示执行。）

使用共享 ProcArray 的另一个重要活动是 ComputeXidHorizons，它必须确定系统范围内任何活动 MVCC 快照的最旧 xmin 的下界。每个单独的后端在 MyProc->xmin 中公布其自身快照的最小 xmin，如果当前没有活动快照（例如，如果在事务之间或尚未为新事务设置快照），则为零。ComputeXidHorizons 取有效 xmin 字段的最小值。它只对 ProcArrayLock 持有共享锁，这意味着与其他并发执行 GetSnapshotData 的后端存在潜在的竞态条件：我们必须确保即将设置其 xmin 的并发后端计算的 xmin 不小于 ComputeXidHorizons 确定的值。我们通过将所有活动 XID 与有效 xmin 一起包含在 MIN() 计算中来确保这一点。事务不能在未获取独占 ProcArrayLock 的情况下退出的规则确保共享 ProcArrayLock 的并发持有者将计算相同的当前活动 XID 最小值：在我们持有共享 ProcArrayLock 时，没有事务，特别是最老的事务，可以退出。因此，ComputeXidHorizons 对最小活动 XID 的看法将与任何并发 GetSnapshotData 相同，因此它不会产生高估。如果根本没有活动事务，ComputeXidHorizons 使用 latestCompletedXid + 1，这是并发或后续 GetSnapshotData 调用可能计算的 xmin 的下界。（我们知道不会有小于此值的 XID 即将出现在 ProcArray 中，因为上面讨论的 XidGenLock 互锁。）

由于 GetSnapshotData 对性能至关重要，它不执行精确的 oldest-xmin 计算（直到 v14 版本之前都是这样做的）。快照的内容仅取决于其他后端的 xid，而不是它们的 xmin。由于后端的 xmin 变化比其 xid 频繁得多，让 GetSnapshotData 查看 xmin 可能导致大量不必要的缓存行乒乓效应。相反，GetSnapshotData 更新近似阈值（一个保证可以删除比它更早的已删除行，另一个确定不能删除比它更新的已删除行）。GlobalVisTest\* 使用这些阈值来做不可见性决策，必要时回退到 ComputeXidHorizons。

注意，虽然可以确定两个并发执行的 GetSnapshotData 将为它们自己的快照计算相同的 xmin，但对于 ComputeXidHorizons 计算的地平线没有这样的保证。这是因为我们允许无 XID 的事务异步清除它们的 MyProc->xmin（不获取 ProcArrayLock），所以一次执行可能会看到曾经是最旧的 xmin，而另一次则不会。这没关系，因为阈值只需要是有效的下界。如上所述，我们已经假设 xid 字段的获取/存储是原子的，所以对 xmin 也做同样的假设不会带来额外风险。

## pg_xact 和 pg_subtrans

pg_xact 和 pg_subtrans 是事务相关信息的永久（磁盘）存储。每种只有有限数量的页面保存在内存中，因此在许多情况下不需要实际从磁盘读取。但是，如果有长时间运行的事务或后端闲置且事务打开，则可能需要能够从磁盘读写这些信息。它们还允许信息在服务器重启后保持永久。

pg_xact 记录每个已分配 XID 的事务的提交状态。事务可以处于进行中、已提交、已中止或"子提交"状态。最后一种状态意味着它是一个不再运行的子事务，但其父事务尚未更新其状态。没有必要将子事务的事务状态更新为子提交，所以我们可以将其推迟到主事务提交。将事务标记为子提交的主要作用是在事务状态分布在多个 clog 页面时提供原子提交协议。因此，每当事务状态分布在多个页面上时，我们必须使用两阶段提交协议：第一阶段是将子事务标记为子提交，然后我们将顶级事务及其所有子事务标记为已提交（按此顺序）。因此，未中止的子事务即使已经完成也显示为进行中，子提交状态在主事务提交期间表现为非常短暂的过渡状态。子事务中止总是在发生时立即在 clog 中标记。当事务状态全部适合单个 CLOG 页面时，我们以原子方式将它们全部标记为已提交，而不必费心中间的子提交状态。

保存点使用子事务实现。子事务是事务内部的事务；其提交或中止状态不仅取决于它是否自行提交，还取决于其父事务是否提交。为了在事务中实现多个保存点，我们允许无限的事务嵌套深度，因此任何特定子事务的提交状态取决于每个祖先事务的提交状态。

"子事务父级"（pg_subtrans）机制为每个具有 XID 的事务记录其父事务的 TransactionId。此信息在子事务被分配 XID 时立即存储。顶级事务没有父级，因此它们的 pg_subtrans 条目设置为默认值零（InvalidTransactionId）。

pg_subtrans 用于检查相关事务是否仍在运行——事务的主 Xid 记录在 ProcGlobal->xids[] 中，PGPROC->xid 中有副本，但由于我们允许子事务任意嵌套，我们无法将所有 Xid 放入共享内存，因此必须将它们存储在磁盘上。但是，请注意，对于每个事务，我们保留已知属于事务树的 Xid 的"缓存"，因此除非我们知道缓存已溢出，否则可以跳过查看 pg_subtrans。有关详细信息，请参阅 storage/ipc/procarray.c。

slru.c 是 pg_xact 和 pg_subtrans 的支持机制。它为内存缓冲页面实现 LRU 策略。pg_xact 的高级例程在 transam.c 中实现，而低级函数在 clog.c 中。pg_subtrans 完全包含在 subtrans.c 中。

## 预写日志编码

WAL 子系统（在代码中也称为 XLOG）的存在是为了保证崩溃恢复。它还可用于提供时间点恢复，以及通过日志传送的热备复制。以下是关于其设计中不太明显方面的一些说明。

预写日志的基本假设是日志条目必须在它们描述的数据页面更改之前到达稳定存储。这确保将日志重放到末尾将使我们要达到一致状态，其中没有部分执行的事务。为了保证这一点，每个数据页面（堆或索引）都标记有影响该页面的最新 XLOG 记录的 LSN（日志序列号——实际上是一个 WAL 文件位置）。在 bufmgr 可以写出脏页之前，它必须确保 xlog 至少已刷新到页面的 LSN。这种低级交互通过不在必要时等待 XLOG I/O 来提高性能。LSN 检查仅存在于共享缓冲区管理器中，而不存在于用于临时表的本地缓冲区管理器中；因此临时表上的操作不得进行 WAL 记录。

在 WAL 重放期间，我们可以检查页面的 LSN 以检测当前日志条目记录的更改是否已应用（如果页面 LSN >= 日志条目的 WAL 位置，则已应用）。

通常，日志条目仅包含足够的信息来重做页面（或小页面组）上的单个增量更新。这仅在文件系统和硬件将数据页面写入实现为原子操作时才有效，这样页面永远不会处于损坏的部分写入状态。由于这在实际中往往是站不住脚的假设，我们记录额外信息以允许完全重建修改的页面。检查点后影响给定页面的第一个 WAL 记录包含整个页面的副本，我们通过恢复该页面副本来实现重放，而不是重做更新。（这比数据存储本身更可靠，因为我们可以检查 WAL 记录 CRC 的有效性。）我们可以通过注意页面的旧 LSN 是否在最后一个检查点的 WAL 末尾（RedoRecPtr）之前来检测"检查点后的第一个更改"。

执行 WAL 记录操作的一般模式是：

1.  Pin 并独占锁定包含要修改的数据页面的共享缓冲区。

2.  START_CRIT_SECTION()（接下来三个步骤中的任何错误都必须导致 PANIC，因为共享缓冲区将包含未记录的更改，我们必须确保这些更改不会到达磁盘。显然，在开始临界区之前，您应该检查条件，例如页面上是否有足够的空闲空间。）

3.  将所需的更改应用于共享缓冲区。

4.  使用 MarkBufferDirty() 将共享缓冲区标记为脏。（这必须在插入 WAL 记录之前发生；参见 SyncOneBuffer() 中的注释。）注意，只有当您写入 WAL 记录时，才应该使用 MarkBufferDirty() 将缓冲区标记为脏；参见下面的"编写提示"。

5.  如果关系需要 WAL 记录，使用 XLogBeginInsert 和 XLogRegister\* 函数构建 WAL 记录，并插入它。（参见下面的"构造 WAL 记录"。）然后使用返回的 XLOG 位置更新页面的 LSN。例如：

        XLogBeginInsert();
        XLogRegisterBuffer(...)
        XLogRegisterData(...)
        recptr = XLogInsert(rmgr_id, info);

        PageSetLSN(dp, recptr);

6.  END_CRIT_SECTION()

7.  解锁并取消 Pin 缓冲区。

复杂更改（如多级索引插入）通常需要由一系列原子操作 WAL 记录来描述。中间状态必须是自洽的，这样如果重放在任何两个操作之间中断，系统仍然是完全功能的。例如，在 btree 索引中，页面分裂需要分配一个新页面，并在父 btree 级别插入一个新键，但由于锁定原因，这必须由两个单独的 WAL 记录反映。重放第一个记录（分配新页面并将元组移动到它）会在页面上设置一个标志，指示键尚未插入到父级。重放第二个记录会清除该标志。这个中间状态在正常操作期间永远不会被其他后端看到，因为子页面上的锁在两个操作之间保持，但如果操作在写入第二个 WAL 记录之前中断，将会看到这个状态。搜索算法像往常一样处理中间状态，但如果插入遇到设置了不完整分裂标志的页面，它将在继续之前通过将键插入父级来完成中断的分裂。

## 构造 WAL 记录

WAL 记录由所有 WAL 记录类型通用的头部、记录特定数据和有关修改的数据块的信息组成。每个修改的数据块都由 ID 号标识，并且可以选择具有与该块关联的更多记录特定数据。如果 XLogInsert 决定需要获取块的完整页面映像，则与该块关联的数据不包括在内。

构造 WAL 记录的 API 由五个函数组成：XLogBeginInsert、XLogRegisterBuffer、XLogRegisterData、XLogRegisterBufData 和 XLogInsert。首先，调用 XLogBeginInsert()。然后使用 XLogRegister\* 函数注册所有修改的缓冲区和重放更改所需的数据。最后，通过调用 XLogInsert() 将构造的记录插入 WAL。

    XLogBeginInsert();

    /* 注册作为此 WAL 记录操作一部分修改的缓冲区 */
    XLogRegisterBuffer(0, lbuffer, REGBUF_STANDARD);
    XLogRegisterBuffer(1, rbuffer, REGBUF_STANDARD);

    /* 注册始终包含在 WAL 记录中的数据 */
    XLogRegisterData(&xlrec, SizeOfFictionalAction);

    /*
     * 注册与缓冲区关联的数据。如果获取完整页面映像，
     * 这将不包括在记录中。
     */
    XLogRegisterBufData(0, tuple->data, tuple->len);

    /* 与缓冲区关联的更多数据 */
    XLogRegisterBufData(0, data2, len2);

    /*
     * 好的，要包含在 WAL 记录中的所有数据和缓冲区
     * 都已注册。插入记录。
     */
    recptr = XLogInsert(RM_FOO_ID, XLOG_FOOBAR_DO_STUFF);

API 函数的详细信息：

void XLogBeginInsert(void)

    必须在 XLogRegisterBuffer 和 XLogRegisterData 之前调用。

void XLogResetInsertion(void)

    从 WAL 记录构造工作区中清除任何当前注册的数据和缓冲区。这仅在您已经调用了 XLogBeginInsert()，但最终决定不插入记录时才需要。

void XLogEnsureRecordSpace(int max_block_id, int ndatas)

    通常，WAL 记录构造缓冲区有以下限制：

    * 可以使用的最高块 ID 是 4（允许五个块引用）
    * 最多 20 个注册数据块

    这些默认限制足以满足大多数更改某些磁盘结构的记录类型。对于需要更多数据或需要修改更多缓冲区的罕见情况，可以通过调用 XLogEnsureRecordSpace() 来提高这些限制。XLogEnsureRecordSpace() 必须在 XLogBeginInsert() 之前调用，并且在临界区之外。

void XLogRegisterBuffer(uint8 block_id, Buffer buf, uint8 flags);

    XLogRegisterBuffer 向 WAL 记录添加有关数据块的信息。block_id 是一个任意数字，用于在重做例程中标识此页面引用。重做时重新找到页面所需的信息——relfilelocator、fork 和块号——都包含在 WAL 记录中。

    如果这是自上次检查点以来对缓冲区的第一次修改，XLogInsert 将自动包含页面内容的完整副本。使用 XLogRegisterBuffer 注册操作修改的每个缓冲区以避免撕裂页面危险非常重要。

    标志控制何时以及如何将缓冲区内容包含在 WAL 记录中。通常，仅当页面自上次检查点以来未被修改，并且仅当 full_page_writes=on 或正在进行在线备份时，才获取完整页面映像。REGBUF_FORCE_IMAGE 标志可用于强制始终包含完整页面映像；这对于重写大部分页面的操作很有用，因此跟踪细节不值得。对于不需要防止撕裂页面的罕见情况，可以使用 REGBUF_NO_IMAGE 标志来抑制获取完整页面映像。REGBUF_WILL_INIT 也抑制完整页面映像，但重做例程必须从头开始重新生成页面，而不查看旧页面内容。重新初始化页面像完整页面映像一样防止撕裂页面危险。

    REGBUF_STANDARD 标志可以与其他标志一起指定，以指示页面遵循标准页面布局。它导致 pd_lower 和 pd_upper 之间的区域从映像中排除，减少 WAL 量。

    如果给出 REGBUF_KEEP_DATA 标志，则即使获取完整页面映像，使用 XLogRegisterBufData() 注册的每个缓冲区数据也包含在 WAL 记录中。

void XLogRegisterData(char \*data, int len);

    XLogRegisterData 用于在 WAL 记录中包含任意数据。如果多次调用 XLogRegisterData()，数据会被追加，并将作为一个连续块提供给重做例程。

void XLogRegisterBufData(uint8 block_id, char \*data, int len);

    XLogRegisterBufData 用于包含与之前使用 XLogRegisterBuffer() 注册的特定缓冲区关联的数据。如果使用相同的块 ID 多次调用 XLogRegisterBufData()，数据会被追加，并将作为一个连续块提供给重做例程。

    如果在插入时获取缓冲区的完整页面映像，则数据不包括在 WAL 记录中，除非使用 REGBUF_KEEP_DATA 标志。

## 编写 REDO 例程

REDO 例程使用 WAL 记录中包含的数据和页面引用来重建页面的新状态。可以使用 xlogreader.c/h 中的记录解码函数和宏从记录中提取数据。

当重放描述多个页面更改的 WAL 记录时，您必须小心正确锁定页面，以防止并发热备查询看到不一致的状态。如果这需要同时持有两个或更多缓冲区锁，您必须以适当的顺序锁定页面，并且在完成所有更改之前不要释放锁。

注意，我们只有在知道操作是序列化的情况下才能使用 PageSetLSN/PageGetLSN()。只有 Startup 进程可以在恢复期间修改数据块，因此 Startup 进程可以执行 PageGetLSN() 而不必担心序列化问题。所有其他进程只有在持有独占缓冲区锁或共享锁加缓冲区头锁时，或者在持有关系的 AccessExclusiveLock 时直接写入数据块而不是通过共享缓冲区时，才能调用 PageSet/GetLSN。

## 编写提示

在某些情况下，我们在不写入前面的 WAL 记录的情况下向数据块写入额外信息。这应该仅在数据可以在崩溃后重建且该操作仅仅是优化性能的情况下发生。当写入提示时，我们使用 MarkBufferDirtyHint() 将块标记为脏。

如果缓冲区是干净的且使用校验和，则 MarkBufferDirtyHint() 插入 XLOG_FPI_FOR_HINT 记录以确保我们获取包含提示的完整页面映像。我们这样做是为了在写入脏页时避免部分页面写入。恢复期间不写入 WAL，因此我们在恢复时简单地跳过因提示而脏化块。

如果您确实决定优化掉 WAL 记录，则必须将对 MarkBufferDirty() 的任何调用替换为 MarkBufferDirtyHint()，否则您将暴露部分页面写入的风险。

堆页面中的全可见提示（PD_ALL_VISIBLE）是一种特殊情况，因为它在某些方面被视为持久更改，在其他方面被视为提示。它必须满足不变性：如果堆页面的关联可见性映射（VM）位被设置，则堆页面本身上的 PD_ALL_VISIBLE 也被设置。清除 PD_ALL_VISIBLE 始终被视为完全持久更改以维持此不变性。此外，如果启用了校验和或 wal_log_hints，设置 PD_ALL_VISIBLE 也被视为完全持久更改以防止撕裂页面。

但是，如果既未启用校验和也未启用 wal_log_hints，如果唯一更改是 PD_ALL_VISIBLE，则撕裂页面无关紧要；因此不获取完整堆页面映像，也不更新堆页面的 LSN。注意：即使有关联的 WAL 记录，在应用此优化时更新堆页面的 LSN 也是不正确的，因为页面的后续修改者（例如不相关的 UPDATE）可能会错误地认为不需要完整页面映像。

## 文件系统操作的预写日志

上一节描述了如何对仅更改共享缓冲区内页面内容的操作进行 WAL 记录。对于那种类型的操作，通常在开始进行实际更改之前检查所有可能的错误情况（例如页面上空间不足）是可能的。因此，我们可以通过将它们包装到临界区中使更改和相关 WAL 日志记录的创建成为"原子"操作——中途失败的几率足够低，如果真的发生，PANIC 是可以接受的。

显然，这种方法不适用于要记录的操作中存在显著失败概率的情况，例如创建新文件或数据库。我们不希望 PANIC，尤其不希望在我们已经写入了说我们执行了操作的 WAL 记录之后 PANIC——如果我们这样做了，记录的重放可能会再次失败并再次 PANIC，使故障无法恢复。这意味着普通的 WAL 规则"在更改之前写入 WAL"不起作用，我们需要为这种情况设计不同的方案。

有几种基本类型的文件系统操作存在这个问题。以下是我们如何处理每一种：

1. 向现有表添加磁盘页面。

此操作根本不进行 WAL 记录。我们通过在表末尾写入一页零来扩展表。我们必须实际执行此写入，以确保文件系统已分配空间。如果写入失败，我们可以正常报错。一旦知道空间已分配，我们就可以通过一个或多个正常的 WAL 记录操作初始化和填充页面。因为我们可能在扩展文件和写出 WAL 条目之间崩溃，所以我们必须将发现表或索引中的全零页面视为非错误条件。在这种情况下，我们可以回收空间以供重用。

2. 创建新表，需要在文件系统中创建新文件。

我们尝试创建文件，如果成功，我们创建一个 WAL 记录说明我们做到了。如果不成功，我们可以抛出错误。注意，有一个窗口期，我们已经创建了文件但尚未向其写入任何 WAL 到磁盘。如果在此期间崩溃，文件将作为"孤儿"留在磁盘上。可以通过让数据库重启搜索 pg_class 中没有已提交条目的文件来清理此类孤儿，但目前没有这样做，因为有可能删除对崩溃取证分析有用的数据。孤儿文件是无害的——最坏情况下它们浪费一点磁盘空间——因为我们在分配新的 relfilenumber OID 时检查磁盘冲突。因此清理并不是真的必要。

3. 删除表，需要可能失败的 unlink()。

我们的方法是先对操作进行 WAL 记录，但将实际 unlink() 调用的失败视为警告而不是错误条件。同样，这可能会留下孤儿文件，但与替代方案相比，这是廉价的。由于我们只有在提交了 DROP TABLE 事务之后才能真正执行 unlink()，无论如何抛出错误都是不可能的。（值得注意的是，关于文件删除的 WAL 条目实际上是删除事务的提交记录的一部分。）

4. 创建和删除数据库和表空间，需要创建和删除目录和整个目录树。

这些情况的处理方式类似于创建单个文件，即我们先尝试执行操作，如果成功则写入 WAL 条目。当然，可能浪费的磁盘空间量要大得多。在创建的情况下，如果创建失败，我们尝试再次删除目录树，以减少浪费空间的风险。删除操作中途失败会导致数据库损坏：DROP 失败，但一些数据已经丢失。对此我们无能为力，而且无论如何这可能是用户不再想要的数据。

在所有这些情况下，如果 WAL 重放无法重做原始操作，我们必须 panic 并中止恢复。DBA 将不得不手动清理（例如，释放一些磁盘空间或修复目录权限），然后重新启动恢复。这是不在成功执行原始操作之前写入 WAL 条目的部分原因。

## 跳过新 RelFileLocator 的 WAL

在 wal_level=minimal 下，如果更改修改了 ROLLBACK 将 unlink 的 relfilenumber，树内访问方法不为该更改写入 WAL。不调用 RelationNeedsWAL() 而写入 WAL 的代码必须检查这种情况。这种跳过是强制性的。如果同一块的 WAL 写入更改 precede WAL 跳过更改，REDO 可能会覆盖 WAL 跳过更改。如果同一块的 WAL 写入更改跟随 WAL 跳过更改，会出现相关问题。当 WAL 记录不包含完整页面映像时，REDO 期望页面与其在记录插入之前的内容匹配。WAL 跳过更改可能根本不会到达磁盘，在 full_page_writes=off 下违反 REDO 的预期。对于任何访问方法，CommitTransaction() 在记录提交之前写入并 fsync 受影响的块。

未来的访问方法最好也这样做。但是，还有两种其他方法可行。首先，访问方法可以通过调用 FlushRelationBuffers() 和 smgrimmedsync() 不可逆地将给定 fork 从 WAL 跳过转换为 WAL 写入。其次，访问方法可以选择无条件地为永久关系写入 WAL。在这些方法下，访问方法回调不得调用对 RelationNeedsWAL() 做出反应的函数。

这仅适用于其重放将修改存储在新 relfilenumber 中的字节的 WAL 记录。它不适用于关于 relfilenumber 的其他记录，例如 XLOG_SMGR_CREATE。因为它在单个 relfilenumbers 级别操作，RelationNeedsWAL() 对于紧密耦合的关系可能不同。考虑 "CREATE TABLE t (); BEGIN; ALTER TABLE t ADD c text; ..."，其中 ALTER TABLE 添加 TOAST 关系。TOAST 关系将跳过 WAL，而拥有它的表不会。ALTER TABLE SET TABLESPACE 将导致表跳过 WAL，但这不会影响其索引。

## 异步提交

从 PostgreSQL 8.3 开始，可以执行异步提交——即，我们不等待提交的 WAL 记录被 fsync'ed。当 synchronous_commit = off 时，我们执行异步提交。我们不执行到提交 LSN 的 XLogFlush()，而只是在共享内存中记录 LSN。然后后端继续其他工作。我们仅为异步提交记录 LSN，不为中止记录；永远不需要刷新一份中止记录，因为崩溃后的假设是事务无论如何都中止了。

当事务正在删除关系时，我们总是强制同步提交，以确保在从文件系统中删除关系之前提交记录已到达磁盘。此外，某些具有不可回滚副作用（例如文件系统更改）的实用命令强制同步提交，以最小化文件系统更改已完成但事务未保证提交的窗口期。

walwriter 定期唤醒（通过 wal_writer_delay）或被唤醒（通过其 latch，由异步提交的后端设置）并执行 XLogBackgroundFlush()。这会检查最后一个完全填充的 WAL 页面的位置。如果该位置向前移动，那么我们写入到该点的所有更改缓冲区，以便在满负载下我们只写入整个缓冲区。如果活动中断且当前 WAL 页面与之前相同，那么我们找出最近异步提交的 LSN，并在需要时写入到该点（即，如果它在当前 WAL 页面中）。如果自上次刷新以来已经过去超过 wal_writer_delay，或者已经写入超过 wal_writer_flush_after 块，WAL 也会刷新到当前位置。这种安排本身将保证异步提交记录在事务完成后最多两次 wal_writer_delay 后到达磁盘。但是，我们也允许 XLogFlush "灵活地"写入/刷新完整缓冲区（即，不在循环 WAL 缓冲区区域的末尾环绕），以最小化在高负载下每个 walwriter 周期填充多个 WAL 页面时发出的写入次数。这使得最坏情况延迟为三个 wal_writer_delay 周期。

异步提交还有一些其他细微要点需要考虑。首先，对于 CLOG 的每个页面，我们必须记住影响该页面的最新提交的 LSN，以便我们可以执行与普通关系页面相同的"先刷新 WAL 再写入"规则。否则，提交记录可能会在 WAL 记录之前到达磁盘。同样，中止记录不需要纳入此考虑。

实际上，我们为每个 clog 页面存储多个 LSN。这与我们在可见性测试期间设置事务状态提示位的方式有关。我们不能在关系页面上设置事务已提交的提示位并使该记录在提交的 WAL 记录之前到达磁盘。由于可见性测试通常在持有缓冲区共享锁时进行，我们没有选项更改页面的 LSN 以保证 WAL 同步。相反，如果我们尚未将 WAL 刷新到与事务关联的 LSN，我们推迟设置提示位。这需要跟踪每个未刷新的异步提交的 LSN。将此数据与 clog 缓冲区关联很方便：因为我们会在写入 clog 页面之前刷新 WAL，我们知道只要保存其提交状态的 clog 页面仍在内存中，就不需要记住事务的 LSN。但是，为每个 clog 位置存储 LSN 的天真方法并不吸引人：LSN 比两位提交状态字段大 32 倍，因此每个 8K clog 缓冲页面我们需要 256K 的额外共享内存。我们选择改为每页面存储较少数量的 LSN，其中每个 LSN 是与该页面上连续事务 ID 范围内的任何事务提交关联的最高 LSN。这以设置事务提示位时可能不必要的延迟为代价节省了存储。

多少个事务应该共享相同的缓存 LSN（N）？如果系统的工作负载仅由小型异步提交事务组成，那么让 N 类似于每个 walwriter 周期的事务数是合理的，因为那是事务真正提交（因此可提示）的粒度。最坏的情况是同步提交事务与稍后提交的异步提交事务共享缓存 LSN；即使我们付费将第一个事务同步到磁盘，我们也无法提示其输出，直到第二个事务同步，最多三个 walwriter 周期后。这主张尽可能保持 N（组大小）小。目前我们将组大小设置为 32，这使得 LSN 缓存空间与实际 clog 缓冲空间大小相同（独立于 BLCKSZ）。

我们可以同时运行同步和异步提交事务是有用的，但这的安全性可能不是立即显而易见的。假设我们有两个事务 T1 和 T2。日志序列号（LSN）是 WAL 序列中记录事务提交的点，因此 LSN1 和 LSN2 是那些事务的提交记录。如果 T2 可以看到 T1 所做的更改，那么当 T2 提交时，LSN2 必须跟在 LSN1 之后。因此，当 T2 提交时，可以确定 T1 所做的所有更改现在也记录在 WAL 中。无论 T1 是异步还是同步，这都是正确的。因此，异步提交和同步提交可以安全地并发工作，而不会危及同步提交写入的数据。子事务在这里不重要，因为最终的磁盘写入仅发生在顶级事务的提交时。

数据块的更改除非 WAL 刷新到数据块 LSN 的点，否则无法到达磁盘。任何尝试将不安全数据写入磁盘的操作都将触发写入，确保该事务和先前事务写入的所有数据的安全。数据块和 clog 页面都受到 LSN 的保护。

临时表的更改不进行 WAL 记录，因此可能在 T1 提交之前到达磁盘，但我们不在乎，因为临时表内容无论如何都不会在崩溃后幸存。

跳过新 relfilenumbers 的 WAL 的数据库写入也是安全的。在这些情况下，数据完全有可能在 T1 提交之前到达磁盘，因为 T1 将在没有任何互锁的情况下将其 fsync 到磁盘。但是，所有这些路径都设计为写入其他事务在 T1 提交之前无法看到的数据。因此，情况与普通 WAL 记录的更新没有什么不同。

## 恢复期间的事务模拟

在恢复期间，我们按发生的顺序重放事务更改。作为此重放的一部分，我们模拟一些事务行为，以便只读后端可以获取 MVCC 快照。我们通过维护属于正在重放的事务的 XID 列表来做到这一点，因此每个已为数据库写入记录 WAL 记录的事务都存在於数组中，直到它提交。更多细节在 procarray.c 的注释中给出。

许多操作根本不写入 WAL 记录，例如只读事务。这些对恢复中的 MVCC 没有影响，我们可以假装它们从未发生过。子事务提交也不写入 WAL 记录，影响很小，因为锁等待者需要等待父事务完成。

并非所有事务行为都被模拟，例如我们不将事务条目插入锁表，也不在内存中维护事务栈。Clog、multixact 和 commit_ts 条目正常创建。Subtrans 在恢复期间维护，但事务树的细节被忽略，所有子事务直接引用顶级 TransactionId。由于提交是原子的，这提供了正确的锁等待行为，同时大大简化了子事务的模拟。

恢复中锁定机制的更多细节在 Lock rmgr 代码的注释中给出。
