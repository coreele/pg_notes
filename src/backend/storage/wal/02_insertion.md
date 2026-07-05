# WAL 记录插入

## 核心设计思想

- **两阶段构造**：注册阶段收集数据，组装阶段按 WAL 格式链接
- **零拷贝**：通过指针链接数据，无数据移动，仅修改 `XLogRecData.next`
- **对象池**：预分配 `XLogRecData` 数组，快速重置
- **LSN 预留**：先计算所需 WAL 空间，预留 LSN，再复制数据

## 关键文件与 API

**源代码**: `src/backend/access/transam/xloginsert.c`
**头文件**: `src/include/access/xloginsert.h`, `src/include/access/xlog_internal.h`, `src/include/access/xlog.h`

**核心 API**:

```c
// 第一阶段：注册
void XLogBeginInsert(void);                                    // 开始构造新的 WAL 记录
void XLogRegisterData(char *data, uint32 len);                 // 注册主数据 (不与页面绑定)
void XLogRegisterBuffer(uint8 block_id, Buffer buffer,         // 注册被修改的 buffer
                        uint8 flags);
void XLogRegisterBufData(uint8 block_id, char *data,           // 注册 buffer 专属数据
                         uint32 len);
void XLogResetInsertion(void);                                 // 放弃当前记录的构造

// 第二阶段：插入
XLogRecPtr XLogInsert(RmgrId rmid, uint8 info);               // 组装并插入 WAL

// 容量预留
void XLogEnsureRecordSpace(int max_block_id, int ndatas);     // 扩展记录容量 (默认5 blocks, 20 datas)
```

---

## 1. 全局注册状态

`xloginsert.c` 使用静态变量保存当前记录的构造信息。每个进程独立持有，无需锁。

```c
// === 主数据 (Main Data) ===
// 通过 XLogRegisterData 注册，不与任何 buffer 绑定
static XLogRecData *rdatas;              // 对象池数组
static int   num_rdatas;                 // 当前使用数量
static XLogRecData *mainrdata_head;      // main data 链表头
static XLogRecData *mainrdata_last;      // main data 链表尾
static uint64 mainrdata_len;             // main data 总长度
static int   max_rdatas;                 // 池大小 (默认 20)

// === Buffer 数据 ===
// 通过 XLogRegisterBuffer/XLogRegisterBufData 注册
typedef struct {
    bool        in_use;                  // 此槽被使用
    uint8       flags;                   // REGBUF_* 标志
    RelFileLocator rlocator;             // Relation 文件定位器
    ForkNumber  forkno;                  // fork 类型
    BlockNumber block;                   // 块号
    Page        page;                    // 页面内容指针
    bool        begins_critical_section; // 由 REGBUF_IN_CRIT_SECTION 设置的标志

    XLogRecData *rdata_head;             // 该 buffer 的数据链表头
    XLogRecData *rdata_tail;             // 该 buffer 的数据链表尾
    uint32      rdata_len;               // 该 buffer 的数据总长度

    XLogRecData bkp_rdatas[2];           // 备用图像的数据节点
    XLogRecData *bkp_rdata_tail;
} registered_buffer;

static registered_buffer *registered_buffers;  // 缓冲区数组
static int  max_registered_buffers;            // 默认 5+1 个块
static int  max_registered_block_id;           // 实际使用的最大 block_id
```

### 对象池设计

`rdatas` 数组作为对象池，避免每次插入时的 malloc/free：

```c
// 初始化 (XLogBeginInsert):
num_rdatas = 0;
mainrdata_len = 0;
mainrdata_head = NULL;
mainrdata_last = NULL;

// 使用 (XLogRegisterData):
rdatas[num_rdatas].data = data;
rdatas[num_rdatas].len  = len;
rdatas[num_rdatas].next = NULL;
// 链接到 main data 链表的末尾
if (mainrdata_head == NULL)
    mainrdata_head = &rdatas[num_rdatas];
else
    mainrdata_last->next = &rdatas[num_rdatas];
mainrdata_last = &rdatas[num_rdatas];
mainrdata_len += len;
num_rdatas++;
```

---

## 2. 完整插入流程

```
XLogBeginInsert()                    ← 重置全局状态
    │
    ├─ XLogRegisterBuffer(0, buf)    ← 声明修改的页面
    │     registered_buffers[0].in_use = true
    │     registered_buffers[0].page   = BufferGetPage(buf)
    │
    ├─ XLogRegisterBufData(0, ...)   ← buffer 专属数据（可选，可多次）
    │     追加到 registered_buffers[0].rdata_head 链表
    │
    ├─ XLogRegisterData(&xlrec, ...) ← 主数据（不与页面绑定，可多次）
    │     追加到 mainrdata_head 链表
    │
    └─ XLogInsert(rmid, info)        ← 组装、预留、复制、返回 LSN
          │
          ├─ XLogRecordAssemble()    ← 组装链表
          ├─ XLogInsertRecord()      ← 复制到 WAL Buffer
          └─ 返回 XLogRecPtr
```

---

## 3. XLogInsert — 插入核心

```c
// xloginsert.c (简化逻辑)
XLogRecPtr XLogInsert(RmgrId rmid, uint8 info) {
    XLogRecData *rechdr_rdt;       // 组装后的链表（包含头部）
    XLogRecPtr   EndPos;           // 记录结束位置 (LSN)
    bool         doPageWrites;

    // === 步骤 1: 组装 ===
    rechdr_rdt = XLogRecordAssemble(rmid, info);

    // === 步骤 2: 计算所需空间 ===
    uint32 rechdr_len = rechdr_rdt->len;
    for (XLogRecData *r = rechdr_rdt->next; r != NULL; r = r->next)
        rechdr_len += r->len;

    // === 步骤 3: 写入 WAL Buffer ===
    doPageWrites = (Insert->fullPageWrites || Insert->forcePageWrites);
    EndPos = XLogInsertRecord(rmid, info, rechdr_rdt,
                              rechdr_len, doPageWrites);

    // === 步骤 4: 唤醒 WAL Writer ===
    if (WalWriterSleeping) {
        SetLatch(WalWriterLatch);
        WalWriterSleeping = false;
    }

    return EndPos;  // 返回 WAL 记录的结束 LSN
}
```

### 步骤 1: XLogRecordAssemble — 组装

将注册阶段的分散链表按 WAL 磁盘格式组装成完整链表：

```c
static XLogRecData *XLogRecordAssemble(RmgrId rmid, uint8 info) {
    XLogRecData *result = &hdr_rdt;  // 最终链表头
    XLogRecData *last   = &hdr_rdt;

    // --- 1. 填充 XLogRecord 头部 ---
    XLogRecord *rechdr = (XLogRecord *) hdr_scratch;
    rechdr->xl_xid  = GetCurrentTransactionIdIfAny();
    rechdr->xl_rmid = rmid;
    rechdr->xl_info = info;

    // --- 2. 处理每个注册的 buffer (按 block_id 顺序) ---
    for (int block_id = 0; block_id <= max_registered_block_id; block_id++) {
        registered_buffer *buffer = &registered_buffers[block_id];
        if (!buffer->in_use) continue;

        // a) 确定是否需要完整页面映像 (FPW)
        bool needs_backup = XLogCheckBufferNeedsBackup(buffer);
        bool needs_data;

        if (needs_backup) {
            // 保存完整页面映像到 bkp_rdatas
            XLogRecordAssembleFullPageImage(buffer, &last);
        }

        // b) 确定是否需要 buffer-specific 数据
        // 如果有 FPW 且未设 REGBUF_KEEP_DATA → 可以省略
        needs_data = (buffer->rdata_len > 0)
                  && (!needs_backup || (buffer->flags & REGBUF_KEEP_DATA));

        if (needs_data) {
            last->next = buffer->rdata_head;
            last = buffer->rdata_tail;
        }

        // c) 构建 Block Header
        XLogRecordBlockHeader *bhdr = ...;
        bhdr->block_id    = block_id;
        bhdr->fork_flags  = buffer->forkno;
        bhdr->data_length = needs_data ? buffer->rdata_len : 0;
    }

    // --- 3. 拼接 main data ---
    if (mainrdata_len > 0) {
        last->next = mainrdata_head;
        last = mainrdata_last;
    }

    // --- 4. 计算总长度和 CRC ---
    rechdr->xl_tot_len = total_len;
    rechdr->xl_prev = GetXLogInsertRecPtr();  // 上一条记录的 LSN
    INIT_CRC32C(rechdr->xl_crc);
    COMP_CRC32C(...);

    last->next = NULL;
    return result;
}
```

**组装结果示意图**：

```
调用方注册的数据链表:
  Main Data:   [xlrec] → [extra_info] → NULL
  Buffer 0:    [tuple_data] → NULL
  Buffer 1:    [index_entry] → [index_entry2] → NULL

组装后的 WAL 链表:
  [Header] → [Block0 Header]
          → [Block0 FPW Image] (如有)
          → [Block0 Buffer Data]
          → [Block1 Header]
          → [Block1 Buffer Data]
          → [Main Data Header]
          → [xlrec][extra_info]
          → NULL
```

### XLogCheckBufferNeedsBackup — FPW 判定

```c
bool XLogCheckBufferNeedsBackup(registered_buffer *buffer) {
    // 以下情况不需要备份:
    if (buffer->flags & REGBUF_NO_IMAGE)         return false;
    if (buffer->flags & REGBUF_WILL_INIT)        return false;

    // 检查是否需要完整页面映像:
    // 条件: full_page_writes = on (或在备份中)
    //      且页面 LSN < 上次 checkpoint 的 redo 点
    //      (即自上次 checkpoint 以来该页首次被修改)
    if (Insert->fullPageWrites || Insert->forcePageWrites) {
        if (PageGetLSN(buffer->page) < RedoRecPtr)
            return true;
    }
    if (buffer->flags & REGBUF_FORCE_IMAGE)       return true;

    return false;
}
```

### 步骤 2: XLogInsertRecord — 写入 WAL Buffer

```c
// xlog.c (简化逻辑)
static XLogRecPtr XLogInsertRecord(RmgrId rmid, uint8 info,
                                    XLogRecData *rechdr_rdt,
                                    uint32 rechdr_len,
                                    bool doPageWrites) {
    // 1. 获取插入锁 (多进程并发写入)
    WALInsertLockAcquire();

    // 2. 预留 WAL 空间
    //    Insert->CurrPos 记录当前插入位置
    //    需要预留 rechdr_len 字节
    reserveSpace(rechdr_len, &StartPos, &EndPos);

    // 3. 将 WAL 记录复制到 WAL Buffer (环形缓冲区)
    CopyXLogRecordToWAL(rechdr_len, isLogSwitch,
                        rechdr_rdt, StartPos, EndPos);

    // 4. 更新插入位置
    recordXLogRecPtr = StartPos;
    Insert->CurrPos = EndPos;

    // 5. 释放插入锁
    WALInsertLockRelease();

    // 6. 更新 Buffer 的 LSN
    for (block_id...) {
        if (registered_buffers[block_id].in_use) {
            PageSetLSN(registered_buffers[block_id].page, recordXLogRecPtr);
        }
    }

    return EndPos;
}
```

### CopyXLogRecordToWAL — 复制到环形缓冲区

WAL Buffer 是一个**环形缓冲区** (`XLogCtl->pages`)，大小为 `wal_buffers` (默认 -1, 即 `shared_buffers/32`, 最小 64KB)。

```c
static void CopyXLogRecordToWAL(uint32 write_len, bool isLogSwitch,
                                 XLogRecData *chain,
                                 XLogRecPtr StartPos, XLogRecPtr EndPos) {
    // WAL Buffer 相关的指针和字节偏移
    char *buffer = XLogCtl->pages;
    uint32 byteStart = StartPos % XLogSegSize;  // 在段文件内的偏移
    uint32 byteEnd   = EndPos % XLogSegSize;

    // 可能跨越 WAL Buffer 末尾 (环形)
    if (byteEnd < byteStart) {
        // 复制到 buffer[byteStart .. 缓冲区末尾]
        // + 复制到 buffer[0 .. byteEnd]
    } else {
        // 复制到 buffer[byteStart .. byteEnd]
    }

    // 遍历 XLogRecData 链表，调用 memcpy
    for (XLogRecData *r = chain; r != NULL; r = r->next) {
        memcpy(buffer + curOffset, r->data, r->len);
        curOffset += r->len;
    }
}
```

---

## 4. 并发插入 — WALInsertLock

多个后端可以同时写入 WAL。PostgreSQL 使用 **插入锁分区** (`WALInsertLocks`) 实现并发：

```c
// xlog.c
#define NUM_XLOGINSERT_LOCKS  8

typedef struct {
    LWLock      lock;           // 轻量级锁
    XLogRecPtr  insertingAt;    // 此锁的保护区域末尾
    // ...
} WALInsertLock;

static WALInsertLock *WALInsertLocks;  // 8 个锁的数组
```

**并发写入流程**：

```
后端 A:                           后端 B:
AcquireLock(lock_0);              AcquireLock(lock_1);
reserveSpace(100B, &s0, &e0);     reserveSpace(50B, &s1, &e1);
// e0 = CurrPos + 100              // e1 = CurrPos + 150
CopyXLogRecordToWAL(...);         CopyXLogRecordToWAL(...);
// 写入 s0..e0 区域               // 写入 s1..e1 区域
ReleaseLock(lock_0);              ReleaseLock(lock_1);
                                   // WAL Buffer 布局:
                                   // [...记录A...][...记录B...]
                                   //    s0    e0    s1    e1
```

锁保护的是"预留空间"步骤，确保 A 和 B 不会分配到重叠的区域。复制操作并行进行（因为区域不重叠）。

---

## 5. 主数据 (Main Data) vs 缓冲区专属数据 (BufData)

### 核心区别

| 特性 | `XLogRegisterData` (Main Data) | `XLogRegisterBufData` (BufData) |
|------|-------------------------------|--------------------------------|
| **绑定** | 不与任何页面绑定 | 必须绑定到已注册的 buffer (block_id) |
| **大小限制** | 无 | 每个 buffer 最大 65535 字节 (`uint16`) |
| **FPW 时的行为** | **始终包含** | 如取 FPW 且未设 `REGBUF_KEEP_DATA`，则**省略** |
| **用途** | 操作元信息 (offnum, flags, split info) | 页面修改所需的数据 (新 tuple、删除列表) |
| **在记录中的位置** | **最后** (所有 block data 之后) | 在其所属 block 的 FPW 之后 |

### 判定规则 (决策树)

```
数据是否明确属于某个页面 (page)?
  ├─ 是 → 使用 BufData (XLogRegisterBufData)
  │       └─ 回放时是否需要该数据来重做修改? 且大小 < 64KB?
  │             ├─ 是 → BufData ✓
  │             └─ 否 → 考虑 Main Data 或拆分
  └─ 否 → 使用 Main Data (XLogRegisterData)
          (元信息、跨页信息、>64KB 的数据)
```

### 实例：Heap Insert

```c
static void log_heap_insert(Relation rel, Buffer buffer, HeapTuple newtup) {
    xl_heap_insert xlrec;
    XLogBeginInsert();

    // ① 注册被修改的页面
    XLogRegisterBuffer(0, buffer, REGBUF_STANDARD);

    // ② 主数据：插入的 offnum, flags (不与 buffer 绑定，始终包含)
    xlrec.offnum = ItemPointerGetOffsetNumber(&(newtup->t_self));
    xlrec.flags  = 0;
    XLogRegisterData((char *) &xlrec, SizeOfHeapInsert);

    // ③ Buffer 专属数据：新 tuple 内容 (如果取了 FPW 可省略)
    XLogRegisterBufData(0,
                        (char *) newtup->t_data + SizeofHeapTupleHeader,
                        newtup->t_len - SizeofHeapTupleHeader);

    recptr = XLogInsert(RM_HEAP_ID, XLOG_HEAP_INSERT);
    PageSetLSN(BufferGetPage(buffer), recptr);
}
```

**生成的 WAL 布局**：

```
无 FPW 时:
  [XLogRecord Header]
  [Block 0: Header | tuple 数据 (BufData) ]
  [Main Data: xlrec (offnum, flags)]

有 FPW 时 (省略 BufData):
  [XLogRecord Header]
  [Block 0: Header | 完整页面镜像 (FPW) ]
  [Main Data: xlrec (offnum, flags)]
```

### 实例：B-Tree Split

```c
static void log_btree_split(Relation rel, Buffer leftbuf, Buffer rightbuf,
                            OffsetNumber firstright, ...) {
    XLogBeginInsert();

    XLogRegisterBuffer(0, leftbuf, REGBUF_STANDARD);
    // 可以不提供 BufData，因为 FPW 已包含左半页的全部内容

    XLogRegisterBuffer(1, rightbuf, REGBUF_STANDARD | REGBUF_WILL_INIT);
    // REGBUF_WILL_INIT: redo 时会重新生成右半页，所以不需要 FPW
    XLogRegisterBufData(1, rightpage_tuples, len);  // 右半页的 tuple 数据

    // Main Data: split 元信息 (firstright, newitemoff 等)
    XLogRegisterData(&split_meta, sizeof(split_meta));

    XLogInsert(RM_BTREE_ID, XLOG_BTREE_SPLIT);
}
```

---

## 6. Buffer 注册标志详解

```c
// src/include/access/xloginsert.h

// REGBUF_STANDARD — 标准页面，FPW 时排除 pd_lower~pd_upper 之间的空洞
#define REGBUF_STANDARD     0x01

// REGBUF_FORCE_IMAGE — 强制包含完整页面映像 (即使不是首次修改)
#define REGBUF_FORCE_IMAGE  0x02

// REGBUF_NO_IMAGE — 不生成完整页面映像 (操作自己保证不会产生撕裂页)
#define REGBUF_NO_IMAGE     0x04

// REGBUF_WILL_INIT — Redo 会重新初始化此页面 (不需要镜像)
#define REGBUF_WILL_INIT    0x08

// REGBUF_KEEP_DATA — 即使有 FPW 也保留 BufData
#define REGBUF_KEEP_DATA    0x10
```

---

## 7. 常见错误

### 错误 1: 忘记注册 buffer 就注册 BufData

```c
// ❌ 错误
XLogRegisterBufData(0, data, len);  // block_id 0 未注册 → Assert 失败

// ✅ 正确
XLogRegisterBuffer(0, buf, REGBUF_STANDARD);
XLogRegisterBufData(0, data, len);
```

### 错误 2: BufData 超过 64KB 限制

```c
// ❌ 错误
char huge[100000];
XLogRegisterBufData(0, huge, 100000);  // 超出 UINT16_MAX

// ✅ 正确: 拆分为多次调用
XLogRegisterBufData(0, huge, 60000);
XLogRegisterBufData(0, huge + 60000, 40000);

// 或使用 Main Data (无大小限制)
XLogRegisterData(huge, 100000);
```

### 错误 3: 临界区内遗漏 XLogInsert

```c
// ❌ 错误: 修改了 buffer 但没有写 WAL
START_CRIT_SECTION();
PageAddItem(page, ...);
MarkBufferDirty(buffer);
// 忘记 XLogInsert() → 崩溃后数据丢失
END_CRIT_SECTION();
```

---

## 8. 插入流程性能要点

| 优化点 | 实现 | 效果 |
|--------|------|------|
| **零拷贝** | XLogRecData 链表，只修改 next 指针 | 避免 memcpy 构造记录 |
| **对象池** | rdatas 数组栈分配，num_rdatas 快速重置 | 无 malloc/free |
| **并发插入** | 8 个 WALInsertLock 分区 | 8 个后端可并行写入 WAL |
| **环形缓冲区** | WAL Buffer 复用，只需一个 memcpy | 简单高效 |
| **延迟标记脏页** | 先 MarkBufferDirty，后写 WAL | 确保一致性 |
| **批量唤醒** | WAL Writer 在插入后通过 latch 唤醒 | 减少系统调用 |

---

## 9. 调用链全景

```
INSERT/UPDATE/DELETE
  │
  ▼
heap_insert / heap_update / heap_delete
  │
  ▼
log_heap_insert / log_heap_update / log_heap_delete   (heapam_handler.c)
  │
  ▼
START_CRIT_SECTION()
  │
  ├─ MarkBufferDirty(buffer)
  │
  ├─ XLogBeginInsert()
  ├─ XLogRegisterBuffer(0, buffer, REGBUF_STANDARD)
  ├─ XLogRegisterData(&xlrec, ...)                   ← main data
  ├─ XLogRegisterBufData(0, tup_data, ...)            ← buf data
  │
  ├─ recptr = XLogInsert(RM_HEAP_ID, XLOG_HEAP_INSERT)
  │   │
  │   ├─ XLogRecordAssemble(rmid, info)
  │   │     ├─ 计算 FPW 需求 (XLogCheckBufferNeedsBackup)
  │   │     ├─ 按 block_id 顺序链接 block data
  │   │     ├─ 拼接 main data
  │   │     └─ 计算 CRC
  │   │
  │   └─ XLogInsertRecord(rmid, info, rdata_chain, ...)
  │         ├─ WALInsertLockAcquire()       ← 获取插入锁
  │         ├─ Reserve WAL space            ← 预留空间
  │         ├─ CopyXLogRecordToWAL()         ← memcpy 到 WAL Buffer
  │         ├─ Mark WAL page dirty           ← WAL Buffer 页标记
  │         └─ WALInsertLockRelease()
  │
  ├─ PageSetLSN(page, recptr)               ← 更新页面 LSN
  │
  └─ END_CRIT_SECTION()
```

---

**最后更新**: 2026-07 | **适用版本**: PostgreSQL 16.x
