**资源所有者（Resource Owners）相关说明**

## 概述

ResourceOwner 对象是一个旨在简化查询相关资源（如缓冲区引脚 buffer pins 和表锁）管理的概念。这些资源需要以可靠的方式进行跟踪，以确保即使查询因错误而失败，也能在查询结束时释放它们。与其期望整个执行器拥有无懈可击的数据结构，我们将此类资源的跟踪工作局部化到一个单独的模块中。

ResourceOwner API 的设计借鉴了我们的 MemoryContext API，后者在防止内存泄漏方面已被证明非常灵活且成功。特别是，我们允许 ResourceOwner 拥有子 ResourceOwner 对象，从而形成资源所有者的“森林”结构；释放父 ResourceOwner 时，会同时作用于其所有直接和间接子对象。

（虽然将 ResourceOwners 和 MemoryContexts 统一为单一对象类型颇具诱惑力，但由于它们的使用模式存在显著差异，这样做可能并无实际帮助。）

我们会为每个事务或子事务创建一个 ResourceOwner，也为每个 Portal 创建一个。在 Portal 执行期间，全局变量 `CurrentResourceOwner` 指向该 Portal 的 ResourceOwner。这使得 `ReadBuffer` 和 `LockAcquire` 等操作能够将所获取资源的所有权记录在该 ResourceOwner 对象中。

当 Portal 关闭时，任何剩余的资源（通常仅是锁）将移交给当前事务负责。这在实现上表现为将 Portal 的 ResourceOwner 设为当前事务 ResourceOwner 的子对象。`resowner.c` 会在释放子对象时自动将资源转移给父对象。同样，子事务的 ResourceOwner 也是其直接父事务的子对象。

我们需要事务相关的 ResourceOwner 以及 Portal 相关的 ResourceOwner，因为事务可能会在没有关联 Portal 存在的情况下发起需要资源的操作（例如查询解析）。

## API 概览

ResourceOwner 的基本操作包括：

*   **创建**一个 ResourceOwner
*   将某些资源与 ResourceOwner **关联**或**解除关联**
*   **释放**（Release）ResourceOwner 的资产（释放所有拥有的资源，但不释放 owner 对象本身）
*   **删除**（Delete）一个 ResourceOwner（包括子 owner 对象）；在此之前必须已释放所有资源

此 API 直接支持 `src/backend/utils/resowner/resowner.c` 中 `ResourceOwnerData` 结构体定义所列出的资源类型。其他对象可以通过在其内部记录所属 ResourceOwner 的地址来与 ResourceOwner 关联。API 提供了钩子机制，允许其他模块在 ResourceOwner 释放期间介入，以便扫描各自的数据结构并找到需要删除的对象。

**锁的特殊处理**：

**锁**的处理方式较为特殊，因为在非错误情况下，即使锁最初是由子事务或 Portal 获取的，也应持有至事务结束。因此，如果 `isCommit` 为真，对子 ResourceOwner 执行“释放”操作时，会将锁的所有权**转移**给父对象，而不是真正释放锁。

只要处于事务内部，全局变量 `CurrentResourceOwner` 就指示当前获取的资源应归属于哪个资源所有者。需要注意的是，当事务之外（或处于失败的事务中）时，`CurrentResourceOwner` 为 NULL。在这种情况下，获取具有 Query 生命周期的资源是无效的。

当取消缓冲区引脚（unpinning a buffer）、释放锁或缓存引用时，`CurrentResourceOwner` 必须指向与获取该缓冲区、锁或缓存引用时相同的那个资源所有者。虽然通过额外的簿记工作可以放宽这一限制，但目前看来并无此必要。