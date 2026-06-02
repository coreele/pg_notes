# PostgreSQL WAL 日志构造机制

## 核心设计思想

- **零拷贝**：通过指针链接数据，无数据移动
- **两阶段构造**：注册阶段收集数据，组装阶段按 WAL 格式链接
- **对象池**：数组预分配 `XLogRecData` 结构，快速重置

---

## 1. 关键文件与 API

**源代码**: `src/backend/access/transam/xloginsert.c`
**头文件**: `src/include/access/xloginsert.h`, `src/include/access/xlog_internal.h`

**核心 API**：

```c
void XLogBeginInsert(void);
void XLogRegisterData(char *data, uint32 len);          // 主数据
void XLogRegisterBuffer(uint8 block_id, Buffer buffer, uint8 flags);
void XLogRegisterBufData(uint8 block_id, char *data, uint32 len);    // Buffer 专属数据
XLogRecPtr XLogInsert(RmgrId rmid, uint8 info);
```

---

## 2. 核心数据结构

### 基本结构

```c
typedef struct XLogRecData {
    struct XLogRecData *next;   // 链表指针
    char       *data;           // 原始数据指针（零拷贝）
    uint32      len;            // 数据长度
} XLogRecData;
```

### 全局状态（简化视图）

```c
// Main Data（通过 XLogRegisterData）
static XLogRecData *rdatas;             // 对象池数组
static int num_rdatas;                  // 当前使用数量
static XLogRecData *mainrdata_head;     // main data 链表头
static uint64 mainrdata_len;            // main data 总长度

// Buffer 相关（通过 XLogRegisterBuffer）
typedef struct {
    bool        in_use;
    uint8       flags;
    RelFileLocator rlocator;
    BlockNumber block;
    Page        page;

    XLogRecData *rdata_head;            // 该 buffer 的数据链表
    uint32      rdata_len;
} registered_buffer;

static registered_buffer *registered_buffers;
```

## 主数据（Main Data） vs 缓冲区专属数据（Buffer Data / BufData）

- **主数据（Main Data）**：通过 `XLogRegisterData` 注册。
  - 与特定页面无直接绑定，用于记录操作的元信息或记录级参数（offset、flags、操作类型等）。
  - 不受 64KB 限制（适合较大或跨页的结构化数据）。
  - 在 WAL 组装与回放中**始终包含**，可用于指导后续对 buffer 数据的解析或操作。
  - 示例：`xl_heap_insert` 中的 `offnum`/`flags`、B-tree split 的 split 元信息。

- **缓冲区专属数据（BufData）**：通过 `XLogRegisterBufData(block_id, data, len)` 注册。
  - 与已注册的某个 buffer（通过 `XLogRegisterBuffer`）绑定，描述该页面需要的额外信息以完成回放（例如新 tuple 的字节、要删除的 offset 列表、序列化的 index tuples）。
  - 每个 buf data 有大小限制（<= 65535 字节）；可分片多次注册，调用会追加到该 buffer 的数据链表。
  - 在存在 full-page image 时可以省略（页面镜像已包含所有必要信息），但可用 `REGBUF_KEEP_DATA` 强制包含。

判定要点（简易决策树）：

1. 数据是否明确属于某个页面（page）？是 → BufData；否 → Main Data。
2. 回放时是否必须依赖该数据才能在不含 full-page image 的情况下重做页面修改？是 → BufData。
3. 数据是否可能很大（>64KB）或与多页/多操作共享？是 → Main Data。
4. 数据是否只是操作元信息（计数、标志、类型）？是 → Main Data。

交互与回放要点：

- 必须先对某 block 调用 `XLogRegisterBuffer(block_id, ...)`，然后才能对同一 `block_id` 调用 `XLogRegisterBufData`。
- 组装阶段会先按 block_id 链接每个 buffer 的数据（或 full-page image），最后再拼接 main data；回放时通常先读取 main data 以获取上下文，再按 block 顺序消费 buffer-specific 数据。

示例（简洁）：

```c
// Heap insert
XLogBeginInsert();
XLogRegisterBuffer(0, buffer, REGBUF_STANDARD);
XLogRegisterBufData(0, newtup->t_data, newtup->t_len); // tuple bytes
XLogRegisterData(&xlrec, sizeof(xlrec));               // offnum/flags
XLogInsert(RM_HEAP_ID, XLOG_HEAP_INSERT);

// B-tree split
XLogBeginInsert();
XLogRegisterBuffer(0, leftbuf, REGBUF_STANDARD);
XLogRegisterBufData(0, moved_tuples_for_left, len);
XLogRegisterBuffer(1, rightbuf, REGBUF_STANDARD);
XLogRegisterBufData(1, moved_tuples_for_right, len);
XLogRegisterData(&split_meta, sizeof(split_meta));    // split 元信息（main data）
XLogInsert(RM_BTREE_ID, XLOG_BTREE_SPLIT);
```

---

## 3. WAL 记录构造流程

### 注册阶段

**基本流程**：

```c
XLogBeginInsert();

XLogRegisterBuffer(0, buffer1, REGBUF_STANDARD);        // 标记被修改的页面
XLogRegisterBufData(0, tuple_data, tuple_len);          // 页面专属数据

XLogRegisterData(&xlrec, sizeof(xlrec));                // 主数据（不与页面绑定）

XLogInsert(RM_HEAP_ID, XLOG_HEAP_INSERT);
```

**数据组织**（调用方维护的多个链表）：

```
MainData:    [xlrec] → NULL
Buffer 0:    [tuple_data] → NULL
```

### 组装阶段

`XLogRecordAssemble` 将分散的链表按 WAL 格式合并成完整链表（核心逻辑）：

```c
static XLogRecData *XLogRecordAssemble(RmgrId rmid, uint8 info, ...)
{
    XLogRecData *result = &hdr_rdt;

    // 1. 按 block_id 顺序链接所有 buffer
    for (block_id = 0; block_id < max_block_id; block_id++) {
        buffer = &registered_buffers[block_id];
        if (!buffer->in_use) continue;

        // 如果有 full-page image
        if (needs_backup) {
            result->next = &buffer->bkp_rdatas[0];
            result = buffer->bkp_rdata_tail;
        }
        // 如果需要 buffer-specific 数据
        if (needs_data) {
            result->next = buffer->rdata_head;
            result = buffer->rdata_tail;
        }
    }

    // 2. 最后链接 main data
    if (mainrdata_len > 0) {
        result->next = mainrdata_head;
        result = mainrdata_last;
    }

    result->next = NULL;
    return &hdr_rdt;  // 返回完整 WAL 链表头
}
```

**组装结果**（完整 WAL 记录）：

```
[Header] → [Buffer0 Data] → [Buffer1 Data] → [Main Data] → NULL
```

**关键特点**：

- ✅ 零拷贝：仅修改指针，数据不动
- ✅ 顺序保证：按 block_id 排序
- ✅ 条件包含：根据是否有 full-page image 决定是否包含数据

### WAL 文件格式

```
┌──────────────────────┐
│ XLogRecord Header    │
├──────────────────────┤
│ Block 0:             │
│  ├─ Block Header     │
│  ├─ Full-Page Image  │ (可选)
│  └─ Buffer Data      │
├──────────────────────┤
│ Block 1:             │
│  ├─ Block Header     │
│  ├─ Full-Page Image  │ (可选)
│  └─ Buffer Data      │
├──────────────────────┤
│ Main Data            │
└──────────────────────┘
```

---

## 4. XLogRegisterBuffer vs XLogRegisterBufData

### 核心区别

| 特性         | XLogRegisterBuffer | XLogRegisterBufData           |
| ------------ | ------------------ | ----------------------------- |
| **作用**     | 声明修改哪个页面   | 提供页面修改所需的额外数据    |
| **大小限制** | 无                 | 每个 buffer 最多 65535 字节   |
| **何时包含** | 总是               | 可能因 full-page image 而省略 |

### 定义

**Buffer-specific Data**：与某个特定页面修改紧密相关的**附加信息**，对 WAL 回放是必需的，但**不属于页面本身的内容**。

特征：

- 通过 `block_id` 与特定 buffer 绑定
- 数据在页面外，是额外的结构化信息
- 如果取了 full-page image，可能被省略

### 实例：Heap Insert

```c
static void log_heap_insert(Relation rel, Buffer buffer, HeapTuple newtup)
{
    xl_heap_insert xlrec;

    XLogBeginInsert();

    // ① 注册被修改的页面
    XLogRegisterBuffer(0, buffer, REGBUF_STANDARD);

    // ② 主数据（元信息，不与任何 buffer 绑定）
    xlrec.offnum = ItemPointerGetOffsetNumber(&(newtup->t_self));
    XLogRegisterData((char *) &xlrec, SizeOfHeapInsert);

    // ③ Buffer 专属数据（新 tuple 内容）
    XLogRegisterBufData(0, (char *) newtup->t_data, newtup->t_len);

    XLogInsert(RM_HEAP_ID, XLOG_HEAP_INSERT);
}
```

**生成的 WAL**：

```
[Header: RM_HEAP_ID, XLOG_HEAP_INSERT]
[Block 0 Header: 页面位置信息]
[Tuple Data]        ← XLogRegisterBufData 提供
[Main Data]         ← XLogRegisterData 提供（offset, flags）
```

**为什么需要两者结合？**

- ❌ 仅用 RegisterBuffer：知道改哪页，不知道怎么改
- ❌ 仅用 RegisterData：知道插入什么，不知道插到哪
- ✅ 结合：既知道修改位置，又知道修改内容

### 快速判断

**何时使用 XLogRegisterBufData？**

1. 数据是否与某个特定页面修改相关？→ 是 ✓
2. 回放时是否需要这个数据来重做该页面操作？→ 是 ✓
3. 数据是否已在页面内？→ 否 ✓
4. 数据大小是否 < 64KB？→ 是 ✓

**典型场景**：

| 操作             | Buffer     | BufData        | MainData     |
| ---------------- | ---------- | -------------- | ------------ |
| Heap Insert      | ✓ 目标页面 | ✓ tuple 数据   | ✓ 元信息     |
| B-Tree Split     | ✓ 多页面   | ✓ 移动数据     | ✓ split 信息 |
| Page Vacuum      | ✓ 清理页   | ✓ 删除 offsets | ✓ 元信息     |
| Meta Page Update | ✓ meta 页  | ✗              | ✓ 新 meta    |

---

## 5. 常见错误与限制

### 错误 1：忘记注册 buffer

```c
XLogRegisterBufData(0, data, len);  // ❌ block_id 0 未注册
```

**正确做法**：

```c
XLogRegisterBuffer(0, buffer, flags);
XLogRegisterBufData(0, data, len);
```

### 错误 2：数据超过 BufData 限制

```c
char huge_data[100000];
XLogRegisterBufData(0, huge_data, 100000);  // ❌ 超过 UINT16_MAX
```

**解决**：

- 拆分数据：多次 `XLogRegisterBufData` 调用
- 使用 main data：`XLogRegisterData`（无大小限制）

---

## 6. 总结

### 核心要点

1. **设计精妙**：对象池 + 链表，实现零拷贝、快速重置
2. **两阶段流程**：
   - 注册：收集数据，维护多个独立链表
   - 组装：按 WAL 格式链接成完整链表
3. **三类数据**：
   - `XLogRegisterBuffer`：页面元数据
   - `XLogRegisterBufData`：页面专属数据
   - `XLogRegisterData`：主数据（无页面绑定）

### 性能优势

- ✅ 减少内存分配（对象池）
- ✅ 提升缓存命中率（连续内存）
- ✅ 快速重置（无 free/malloc）
- ✅ 零拷贝重组（仅修改指针）

---

**最后更新**: 2026-05-27 | **适用版本**: PostgreSQL 15.x / 16.x / devel
