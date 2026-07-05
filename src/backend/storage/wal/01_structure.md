# WAL 结构与 LSN

## 1. XLogRecPtr — 日志序列号 (LSN)

### 定义

`XLogRecPtr` 是一个 **64 位无符号整数**，是 WAL 中的 "指针" 或 "地址"，唯一标识 WAL 流中的一个字节位置。

```c
// src/include/access/xlogdefs.h
typedef uint64 XLogRecPtr;
```

### LSN 的构成

```
 XLogRecPtr (64-bit)
 ├─ 高 32 位: 逻辑日志文件号 (基于时间线 0 的编号)
 └─ 低 32 位: 文件内字节偏移

例: 0/1795DEB8
   0x00000000 是高 32 位 (逻辑文件号 = 0)
   0x1795DEB8 是低 32 位 (文件内偏移)
```

每个 WAL 段文件大小为 `WAL_SEGMENT_SIZE` (默认 16MB = 16777216 字节)。逻辑文件号将 LSN 映射到具体的物理文件。

### 关键宏和函数

```c
// src/include/access/xlog_internal.h

// WAL 段文件大小 (编译时常量，默认 16MB)
#define WalSegSz        ((int32) XLOG_SEG_SIZE)       // 16 * 1024 * 1024

// 每页大小 (编译时常量，默认 8KB)
#define XLOG_BLCKSZ     8192

// 从 LSN 提取文件号和段内偏移
#define XLogSegmentOffset(lsn, wal_segsz_bytes)  \
    ((lsn) & ((XLogSegSize) - 1))

// LSN 比较
// 判断 a < b
#define XLByteLT(a, b)       ((uint64) (a) < (uint64) (b))

// 两个 LSN 之间的差值
#define XLByteDifference(a, b)  ((uint64) (a) - (uint64) (b))
```

### LSN 的生命周期

```
 分配 LSN           记录在页面              用于恢复比较               用于 WAL flush
┌──────────┐    ┌──────────┐    ┌──────────────────────┐    ┌──────────────────┐
│XLogInsert│ => │PageSetLSN│ => │PageGetLSN(page)      │ => │XLogFlush(lsn)    │
│返回 LSN   │    │(page, lsn)│    │>= record->lsn ? 跳过 │    │确保 LSN 前已刷盘 │
└──────────┘    └──────────┘    └──────────────────────┘    └──────────────────┘
```

每个数据页面 (堆、索引) 的 `PageHeaderData.pd_lsn` 字段记录影响该页的最新 WAL 记录的 LSN。bufmgr 在写出脏页之前必须确保 WAL 至少已刷到 `pd_lsn`。

### LSN 的空间约束

```
WAL 段文件 16MB = 16777216 字节 (0x1000000)
低 32 位最大表示 4GB → 可以表示 256 个 WAL 段文件

高 32 位最大表示约 40 亿个逻辑文件 → LSN 空间不会耗尽
```

### pg_walinspect 验证

```sql
-- 查看当前 WAL 写入位置
SELECT pg_current_wal_lsn();
-- 结果: 0/1795DEB8

-- 查看 WAL 插入位置
SELECT pg_current_wal_insert_lsn();
```

---

## 2. XLogRecord — WAL 记录物理结构

每条 WAL 记录由一个固定头部和变长的数据体组成。

### XLogRecord 结构体

```c
// src/include/access/xlogrecord.h

typedef struct XLogRecord {
    uint32      xl_tot_len;     // 记录总长度 (含头部)
    TransactionId xl_xid;       // 产生此记录的事务 XID
    XLogRecPtr  xl_prev;        // 指向上一条 WAL 记录的 LSN (链表)
    uint8       xl_info;        // 标志位 (高 4 位) + 资源管理器 (低 4 位)
    RmgrId      xl_rmid;        // 资源管理器 ID (XLOG=0, HEAP=10, BTREE=11 等)
    pg_crc32c   xl_crc;         // 整个记录的 CRC-32C 校验值

    // === 以下是变长部分，跟在固定头部之后 ===

    // XLogRecordBlockHeader 数组 (对每个 block_id)
    //   XLogRecordBlockHeader        — 块基本信息 (block_id, fork, data_length)
    //     XLogRecordBlockImageHeader — 如包含 FPW (图像长度, 压缩信息)
    //     XLogRecordBlockCompressHeader — 如压缩 (LZ4/PGLZ 洞大小)
    //   [Block Image Data]           — 完整页面镜像 (FPW)
    //   [Block Data]                 — buffer-specific data

    // XLogRecordDataHeader[Short|Long] — 主数据部分
    //   [Main Data]                   — 通过 XLogRegisterData 注册的数据
} XLogRecord;
```

### 存储布局

```
 ┌─────────────────────────────────┐
 │  XLogRecord 固定头 (24 bytes)    │
 ├─────────────────────────────────┤
 │  总长度 (xl_tot_len)         4B  │
 │  事务 ID (xl_xid)            4B  │
 │  前一条 LSN (xl_prev)        8B  │
 │  标志 + RMgr (xl_info)       1B  │
 │  资源管理器 (xl_rmid)        1B  │
 │  [2B padding]                    │
 │  CRC-32C (xl_crc)            4B  │
 ├─────────────────────────────────┤
 │  Block 0 头部                    │  ← XLogRecordBlockHeader
 │    block_id                     │
 │    fork_flags                   │
 │    data_length                  │
 ├─────────────────────────────────┤
 │  Block 0 Image 头部 (可选)        │  ← 如果有 FPW
 │    bimg_len                     │
 │    bimg_info                    │
 ├─────────────────────────────────┤
 │  Block 0 Image 数据 (可选)        │  ← 完整页面镜像
 ├─────────────────────────────────┤
 │  Block 0 Buffer 数据 (可选)       │  ← XLogRegisterBufData
 ├─────────────────────────────────┤
 │  Block 1 头部 + Image + Data ... │
 ├─────────────────────────────────┤
 │  Main Data 头部 + 数据           │  ← XLogRegisterData
 └─────────────────────────────────┘
```

### XLogRecordBlockHeader

```c
// src/include/access/xlogrecord.h

typedef struct XLogRecordBlockHeader {
    uint8       block_id;       // 块 ID (0-4 默认, 可变)
    uint8       fork_flags;     // fork 类型 + 标志位
    uint16      data_length;    // 与该块关联的 buffer data 长度 (≤ 65535)
} XLogRecordBlockHeader;

// fork_flags 含义:
//   低 4 位: fork 类型 (MAIN_FORKNUM=0, FSM_FORKNUM=1, VM_FORKNUM=2, INIT_FORKNUM=3)
//   高 4 位: BKPBLOCK_* 标志
//     BKPBLOCK_FORK_MASK    = 0x0F
//     BKPBLOCK_HAS_IMAGE    = 0x10  // 包含完整页面映像
//     BKPBLOCK_HAS_DATA     = 0x20  // 包含 buffer-specific data
//     BKPBLOCK_WILL_INIT    = 0x40  // redo 会重新初始化页面
//     BKPBLOCK_SAME_REL     = 0x80  // 与前一个块相同的 Relation
```

### XLogRecordBlockImageHeader

```c
typedef struct XLogRecordBlockImageHeader {
    uint16      length;         // 完整页面映像字节数 (page size - hole)
    uint16      hole_offset;    // 压缩洞的起始偏移
    uint8       bimg_info;      // 压缩信息
    // bimg_info 标志:
    //   BKPIMAGE_HAS_HOLE       = 0x01  // 页面有空洞 (pd_lower ~ pd_upper)
    //   BKPIMAGE_IS_COMPRESSED  = 0x02  // 页面经过压缩 (LZ4或PGLZ)
    //   BKPIMAGE_APPLY          = 0x04  // 页面可能需要额外应用
} XLogRecordBlockImageHeader;

typedef struct XLogRecordBlockCompressHeader {
    uint16      hole_length;    // 压缩后空洞大小
} XLogRecordBlockCompressHeader;
```

### 头部文件定位常量

```c
// 固定头部大小
#define SizeOfXLogRecord    (offsetof(XLogRecord, xl_crc) + sizeof(pg_crc32c))

// 各变长头部大小
#define SizeOfXLogRecordBlockHeader     (offsetof(XLogRecordBlockHeader, data_length) + sizeof(uint16))
```

### xl_prev 链表

每条 WAL 记录的 `xl_prev` 指向上一条 WAL 记录的起始 LSN，形成后向链表。这个链表使得：
- WAL 读取器可以沿着记录反向遍历
- 恢复时可以顺序应用所有记录
- 便于找到任意记录的上下文

```
LSN:  0/1000000           0/1000100           0/1000200
      ┌─────────┐         ┌─────────┐         ┌─────────┐
      │Record A │ ←────── │Record B │ ←────── │Record C │
      │xl_prev=0│         │xl_prev= │         │xl_prev= │
      │         │         │0/1000000│         │0/1000100│
      └─────────┘         └─────────┘         └─────────┘
```

---

## 3. WAL 段文件格式

### 文件命名

WAL 段文件存储在 `pg_wal/` 目录下，命名规则为 `XXXXXXXXYYYYYYYYYYYY` (24 字符)：

```
000000010000000000000001
│      ││            │
│      ││            └─ 段号 (16进制, 8位 = 低32位 / WalSegSz)
│      │└─ 逻辑文件号 (16进制, 8位 = 高32位)
│      └─ 后缀 (只读, = 0xFF)
└─ 时间线 ID (TimeLineID, 8位)
```

LSN → 文件名：
```
给定 LSN = 0/1795DEB8
高 32 位 → 0 (逻辑文件号)
低 32 位 → 0x1795DEB8

段号 = 0x1795DEB8 / WalSegSz = 0x1795DEB8 / 0x1000000 = 0x17

文件名 = 000000010000000000000017
         ^^^^^^^^ (timeline 1)
```

### 段文件内部布局

每个 WAL 段文件 (16MB) 被组织为一系列 8KB 页：

```
WAL Segment File (16MB)
┌─────────────────────────────────────────────┐  ← LSN 0/00000000
│ Page 0 (8KB)                                │
│  ├─ XLogLongPageHeaderData (标准头+长头)     │
│  │   标准头: xlp_magic, xlp_info, xlp_tli,   │
│  │            xlp_pageaddr, xlp_rem_len      │
│  │   长头:   xlp_sysid, xlp_seg_size,        │
│  │            xlp_xlog_blcksz               │
│  ├─ 首个 WAL 记录 ...                        │
│  └─ Padding                                  │
├─────────────────────────────────────────────┤ ← 0/00002000
│ Page 1 (8KB)                                │
│  ├─ XLogPageHeaderData (标准头)              │
│  ├─ WAL 记录 ...                             │
│  └─ Padding                                  │
├─────────────────────────────────────────────┤ ← 0/00004000
│ Page 2 (8KB)                                │
│  └─ ...                                      │
├─────────────────────────────────────────────┤
│ ... (共 2048 页)                              │
├─────────────────────────────────────────────┤ ← 0/00FFFFF8
│ Page 2047 (8KB)                              │
│  └─ ...                                      │
└─────────────────────────────────────────────┘ ← 0/01000000
```

### XLogPageHeaderData

```c
// src/include/access/xlog_internal.h

typedef struct XLogPageHeaderData {
    uint16      xlp_magic;      // 魔数 = 0xD113  (WAL 版本)
    uint16      xlp_info;       // 标志位 (见下)
    TimeLineID  xlp_tli;        // 创建此页的时间线 ID
    XLogRecPtr  xlp_pageaddr;   // 此页的 LSN 地址
    uint32      xlp_rem_len;    // 从上页跨页的剩余长度 (本页首条记录)
} XLogPageHeaderData;

#define SizeOfXLogShortPHD   MAXALIGN(sizeof(XLogPageHeaderData))

// xlp_info 标志:
#define XLP_LONG_HEADER      0x0002  // 段文件首页, 包含长头部
#define XLP_FIRST_IS_CONTRECORD 0x0001 // 首页首条记录是跨页延续
```

### XLogLongPageHeaderData (仅段文件首页)

```c
typedef struct XLogLongPageHeaderData {
    XLogPageHeaderData  std;            // 标准头
    uint64              xlp_sysid;      // 系统标识符 (pg_control 复制)
    uint32              xlp_seg_size;   // 段文件大小 (16MB)
    uint32              xlp_xlog_blcksz; // WAL 块大小 (8KB)
} XLogLongPageHeaderData;

#define SizeOfXLogLongPHD  MAXALIGN(sizeof(XLogLongPageHeaderData))
```

### 跨页记录

WAL 记录可以跨页边界。当一条记录在一个 8KB 页的最后一部分写不下时：
- 将当前页剩余空间填充零 (`xlp_rem_len` 记录)
- 记录在下一个 8KB 页继续
- 下页的 `xlp_rem_len` 指示从上页延续的记录长度

```
Page N:                              Page N+1:
┌────────────────────┬──────┐       ┌──────────┬──────────────┐
│ Record A (前半)     │ 续   │       │ Record A │ Record B ... │
│                    │ len │       │ (后半)    │              │
└────────────────────┴──────┘       └──────────┴──────────────┘
                      ↑ xlp_rem_len          ↑ xlp_pageaddr
```

---

## 4. XLogRecData — 内存中的零拷贝表示

`XLogRecData` 是 WAL 插入过程中在内存中使用的零拷贝链表结构。它不是磁盘上的格式，而是 `XLogRecordAssemble` 用来构建最终 WAL 记录的中间表示。

```c
// src/include/access/xloginsert.h

typedef struct XLogRecData {
    struct XLogRecData *next;   // 下一个节点
    char       *data;           // 原始数据指针 (零拷贝！)
    uint32      len;            // 数据长度
} XLogRecData;
```

**关键设计原则：零拷贝**
- `data` 字段是指向原始数据的指针，**不是副本**
- 链表操作只修改 `next` 指针
- `XLogRecordAssemble` 将链表重组为最终 WAL 格式时，同样只修改指针
- 避免了 `memcpy` 开销

### XLogRecData 的使用方式

```c
// 注册阶段 (调用方持有数据):
XLogRecData rdatas[3];        // 对象池 (栈分配)
rdatas[0].data = &header;     // 指向栈上的 header
rdatas[0].len  = sizeof(header);
rdatas[0].next = &rdatas[1];

rdatas[1].data = tuple_data;  // 指向堆上的数据
rdatas[1].len  = tuple_len;
rdatas[1].next = &rdatas[2];

rdatas[2].data = &tail;
rdatas[2].len  = sizeof(tail);
rdatas[2].next = NULL;

// 组装阶段:
// XLogRecordAssemble 按 WAL 格式重组指针
// rdatas[0] → rdatas[2] → rdatas[1]  (不需要 memcpy 真实数据)
```

---

## 5. Resource Manager (RMgr)

WAL 记录属于不同的资源管理器，记录类型由 `xl_rmid` + `xl_info` 标识。

```c
// src/include/access/rmgrlist.h (PG 16)

// 部分 RMgr:
#define RM_XLOG_ID          0   // 系统级操作 (checkpoint, 页面初始化)
#define RM_XACT_ID          1   // 事务提交/中止
#define RM_SMGR_ID          2   // 存储管理 (创建/删除 relation)
#define RM_CLOG_ID          3   // Commit Log
#define RM_DBASE_ID         4   // 数据库创建/删除
#define RM_TBLSPC_ID        5   // 表空间
#define RM_HEAP_ID         10   // 堆表操作
#define RM_HEAP2_ID        11   // 堆表操作 (第二部分, 如 VACUUM, FREEZE)
#define RM_BTREE_ID        12   // B-Tree 索引
#define RM_HASH_ID         13   // Hash 索引
#define RM_GIN_ID          14   // GIN 索引
#define RM_GIST_ID         15   // GiST 索引
#define RM_SEQ_ID          16   // Sequence
#define RM_SPGIST_ID       17   // SP-GiST 索引
#define RM_BRIN_ID         18   // BRIN 索引
#define RM_GENERIC_ID      20   // Generic WAL (逻辑解码等)
```

每个 RMgr 的 `xl_info` 高 4 位携带通用标志，低 4 位是操作特定的：

```c
// xl_info 高 4 位 (对所有 RMgr 通用):
#define XLR_INFO_MASK           0x0F
#define XLR_SPECIAL_REL_UPDATE  0x10  // 特殊关系更新
#define XLR_CHECK_CONSISTENCY   0x20  // 需要一致性检查

// 示例: Heap RMgr 的操作码 (低4位)
#define XLOG_HEAP_INSERT        0x00
#define XLOG_HEAP_DELETE        0x10
#define XLOG_HEAP_UPDATE        0x20
#define XLOG_HEAP_HOT_UPDATE    0x30
// ...
```

### RMgr 信息表

```c
// 每个 RMgr 在编译时注册:
const RmgrData RmgrTable[RM_MAX_ID] = {
    [RM_XLOG_ID]    = { .rm_name = "XLOG",      .rm_redo = xlog_redo },
    [RM_XACT_ID]    = { .rm_name = "Transaction", .rm_redo = xact_redo },
    [RM_HEAP_ID]    = { .rm_name = "Heap",       .rm_redo = heap_redo },
    [RM_BTREE_ID]   = { .rm_name = "Btree",      .rm_redo = btree_redo },
    // ...
};
```

---

## 6. WAL 版本与魔数

```c
#define XLOG_PAGE_MAGIC  0xD113   // WAL 页魔数 (0xD113 = "DI" 开头, PG 16)
```

每次 WAL 格式变更时，魔数会随之变化。不同版本的 PostgreSQL 的 WAL 不兼容。

---

**关键文件**:
- `src/include/access/xlogrecord.h` — XLogRecord 结构、Block 头部定义
- `src/include/access/xlogdefs.h` — XLogRecPtr 类型
- `src/include/access/xlog_internal.h` — 页头结构、LSN 宏
- `src/include/access/xloginsert.h` — XLogRecData 结构
- `src/include/access/rmgrlist.h` — Resource Manager 列表
