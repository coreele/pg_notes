# Full Page Writes (FPW)

## 问题：撕裂页 (Torn Page)

操作系统和磁盘硬件通常**不保证**对磁盘页面的写入是原子的。

```
场景：PG 的页面大小 = 8KB，OS 页面大小 = 4KB

checkpointer 将一个 8KB 的脏页刷到磁盘：
  ┌─────────────────┐
  │  Page (8KB)     │
  ├────────┬────────┤
  │ 4KB ①  │ 4KB ②  │
  └────────┴────────┘

OS 分两部分写入：
  ① 4KB 写入成功
  ② 此时发生断电/OS 崩溃

结果：磁盘上有 4KB 新数据 + 4KB 旧数据 → 撕裂页 ❌
```

撕裂页的后果：
- **CRC 校验失败** — 如果启用数据校验和 (`data_checksums = on`)，可检测到页面损坏
- **静默数据损坏** — 如果未启用校验和，无法检测，可能出现索引不匹配、元组损坏等

**为什么 WAL 重放不能修复撕裂页？**

WAL 记录通常只包含增量信息 (如"在 offset N 插入 100 字节")。重放增量 WAL 需要页面处于已知的旧状态。如果页面已经是半损坏的，增量重放可能产生错误结果或崩溃。

---

## 1. 解决方案：检查点后首次修改记录完整页面

```
每次 checkpoint 之后，对每个页面的首次修改：
  不仅记录增量 WAL，还记录完整的页面镜像 (8KB)
```

```
时间线：

  Checkpoint ────────────────────────────────────────────────────►
     │                                                              
     │  页面 A 首次修改:                      页面 A 第二次修改:
     │  WAL = [完整页面镜像 A @ LSN1]         WAL = [增量修改 @ LSN2]
     │                                              
     │  崩溃恢复:                                   
     │  1. 恢复完整页面镜像 A (LSN1)                  
     │  2. 重放后续增量修改 (LSN2...)                 
     │  3. 页面恢复一致                               
```

### 完整页面镜像在 WAL 记录中的位置

```
普通 WAL 记录 (无 FPW):
  [XLogRecord Header]
  [Block 0: Header | Buffer Data ]

带 FPW 的 WAL 记录:
  [XLogRecord Header]
  [Block 0: Header | Image Header | Full Page Image (8KB) | Buffer Data (可选)]
```

---

## 2. FPW 的触发条件

```c
// xloginsert.c: XLogCheckBufferNeedsBackup (简化)

bool XLogCheckBufferNeedsBackup(Block block) {
    Page page = BufferGetPage(buffer);

    // 1. 如果明确不要镜像: 跳过
    if (buffer->flags & REGBUF_NO_IMAGE)    return false;

    // 2. 如果 redo 会重新初始化页面: 跳过
    if (buffer->flags & REGBUF_WILL_INIT)   return false;

    // 3. 如果强制要求镜像: 总是生成
    if (buffer->flags & REGBUF_FORCE_IMAGE) return true;

    // 4. 核心条件: full_page_writes = on + 页面 LSN < 上次 checkpoint 的 redo 点
    if (doPageWrites) {
        if (PageGetLSN(page) <= RedoRecPtr)
            return true;  // 自上次 checkpoint 后该页首次被修改
    }

    return false;
}
```

### RedoRecPtr — checkpoint 重做点

```c
// xlog.c
// RedoRecPtr 记录上次 checkpoint 开始时的 WAL 位置。
// 任何页面 LSN < RedoRecPtr 的页面: 自上次 checkpoint 后首次被修改 → 需要 FPW
// 任何页面 LSN >= RedoRecPtr 的页面: 已在本次 checkpoint 周期内被修改过 → 不需要 FPW
```

```
WAL 流:
... [Checkpoint Record @ LSN=RedoRecPtr] ... [Page A 首次修改: FPW=true] ... [Page A 二次修改: FPW=false] ...
                                              ↑ Page A LSN < RedoRecPtr           ↑ Page A LSN >= RedoRecPtr
```

### GUC 参数

```sql
-- full_page_writes: 控制是否生成完整页面镜像
-- 默认 on，强烈建议保持开启
SHOW full_page_writes;

-- wal_compression: 是否压缩完整页面镜像
-- pglz (默认) | lz4 | zstd | off
SHOW wal_compression;
```

**特殊情况强制开启 FPW**：
- 执行 `pg_basebackup` 期间（在线备份）
- `pg_start_backup()` 调用后（`forcePageWrites = true`）
- 恢复期间（WAL 重放时需要 FPW 作为基础）

---

## 3. FPW 相关的 Buffer 标志

```c
// 在 XLogRegisterBuffer 中通过 flags 控制 FPW 行为:

// REGBUF_STANDARD — 标准页面
//   FPW 包含完整页面但排除 pd_lower~pd_upper 之间的空洞 (优化)
#define REGBUF_STANDARD     0x01

// REGBUF_FORCE_IMAGE — 强制包含 FPW
//   即使页面 LSN >= RedoRecPtr 也生成完整页面映像
//   用于重写了页面大部分内容的操作，增量 WAL 可能比 FPW 还大
#define REGBUF_FORCE_IMAGE  0x02

// REGBUF_NO_IMAGE — 不生成 FPW
//   操作保证不会产生撕裂页 (如操作的是临时页面)
#define REGBUF_NO_IMAGE     0x04

// REGBUF_WILL_INIT — Redo 会重新初始化页面
//   不需要旧页面内容，不需要 FPW (也不能用)
#define REGBUF_WILL_INIT    0x08

// REGBUF_KEEP_DATA — 即使有 FPW 也保留 BufData
//   FPW 包含旧页面数据，但重放可能需要额外的指令 (如设置 pd_lsn)
//   或操作依赖完整页面信息
#define REGBUF_KEEP_DATA    0x10
```

---

## 4. FPW 的页面空洞优化

对于标准页面 (`REGBUF_STANDARD`)，`pd_lower` 和 `pd_upper` 之间的区域是"空洞" — 未被使用的空间，不需要记录到 WAL 中：

```
Standard Page Layout:
  ┌──────────────────┐
  │ PageHeaderData   │
  ├──────────────────┤ ← pd_lower
  │ ItemIdData 数组  │ (行指针)
  ├──────────────────┤
  │                  │
  │  空洞 (hole)     │ ← 不需要记录到 FPW
  │                  │
  ├──────────────────┤ ← pd_upper
  │ 实际元组数据     │
  └──────────────────┘
```

```c
// XLogRecordAssemble 中的空洞处理:

if (buffer->flags & REGBUF_STANDARD) {
    // 记录空洞信息
    bkpb->hole_offset = page->pd_lower;   // 空洞起始
    bkpb->hole_length = page->pd_upper - page->pd_lower;  // 空洞大小

    // WAL 记录中存储: [pd_lower 之前的数据] + [pd_upper 之后的数据]
    // 不存储空洞区域 → 节省 WAL 空间
}
```

### 页面压缩

当 `wal_compression` 启用时，完整页面映像可以被压缩：

```c
// xloginsert.c
if (wal_compression != WAL_COMPRESSION_NONE &&
    (page_std || fullPage) &&
    fpw_len > BLCKSZ / 8)  // 只在页面足够大半满时才压缩
{
    // 尝试 LZ4 或 PGLZ 压缩
    // 如果压缩后比原始小：使用压缩版本
    // 否则：使用原始版本
}
```

| 压缩方法 | 配置值 | 说明 |
|---------|-------|------|
| 不压缩 | `off` | 原始页面大小 |
| PGLZ | `pglz` | PG 内置压缩 (默认) |
| LZ4 | `lz4` | 更快的压缩 (PG 14+) |
| Zstandard | `zstd` | 更高压缩比 (PG 15+) |

---

## 5. 恢复时的 FPW 处理

```c
// xlogreader.c 中的 REDO 例程:

// 恢复期间，对于每条 WAL 记录中的每个 block：
if (record->blocks[block_id].has_image) {
    // 有完整页面映像: 直接恢复页面
    RestoreBlockImage(record, block_id, page);
    // 页面 LSN 被设置为记录的 LSN
    PageSetLSN(page, record->EndRecPtr);
} else {
    // 无完整页面映像: 应用增量修改
    // (例如: 插入元组、删除元组等)
    heap_redo(record);
}
```

### 恢复期间的 FPW 策略

```
恢复期间的 FPW 设置:
- full_page_writes 在恢复期间始终视为 on
- 每个 WAL 记录的每个 block，如果满足条件，都会包含 FPW
- 因为恢复期间没有 "上次 checkpoint" 的概念
  (恢复可能从任意点开始)
```

---

## 6. FPW 的代价

| 代价 | 说明 |
|------|------|
| **WAL 膨胀** | 一条带 FPW 的记录可能高达 8KB + 增量数据。频繁修改小关系的 WAL 量会激增 |
| **I/O 开销** | 更多 WAL 需要写入和同步 |
| **但这是必要的** | 没有 FPW，无法在 OS 非原子写入的情况下安全恢复 |

### FPW 与 checkpoint 间隔的关系

```
checkpoint 间隔越短:
  - FPW 发生越频繁 (更多页面满足 "首次修改" 条件)
  - 但恢复时间越短 (需要重放的 WAL 更少)

checkpoint 间隔越长:
  - FPW 发生越少 (页面被重复修改，LSN 已 >= RedoRecPtr)
  - 但恢复时间越长
```

这就是为什么**调整 `checkpoint_timeout` 和 `max_wal_size` 是重要的性能调优项**。

---

## 7. 为什么不能总是用 FPW 而不是增量 WAL？

如果每条 WAL 记录都包含完整页面镜像，就不需要增量 WAL 了。但这样做的代价：

```
假设一个页面大小为 8KB，执行 100 次 UPDATE：

只用 FPW:   100 × 8KB = 800KB WAL
FPW+增量:    1 × 8KB + 99 × ~100B ≈ 18KB WAL
```

增量 WAL 使 WAL 量**减少约 40-50 倍**在高频更新场景下。

---

## 8. 总结

| 问题 | 答案 |
|------|------|
| **为什么需要 FPW？** | OS/磁盘写入非原子，8KB 页可能被部分写入 (撕裂页) |
| **什么时候触发？** | 页面 LSN < `RedoRecPtr` (自上次 checkpoint 后首次被修改)，且 `full_page_writes = on` |
| **记录在哪里？** | WAL 记录的 Block Image 部分，位于 Block Header 之后 |
| **恢复时如何用？** | 直接恢复完整页面映像，跳过增量 REDO |
| **能否关闭？** | 技术上可以 (`full_page_writes = off`)，但强烈不建议 |
| **如何优化？** | 页面空洞排除 (REGBUF_STANDARD)、压缩 (wal_compression)、合理的 checkpoint 间隔 |

---

**关键源码文件**:
- `src/backend/access/transam/xloginsert.c` — `XLogCheckBufferNeedsBackup`, `XLogRecordAssemble`
- `src/backend/access/transam/xlog.c` — `RedoRecPtr`, `fullPageWrites`, `forcePageWrites`
- `src/include/access/xlogrecord.h` — `XLogRecordBlockImageHeader`
- `src/include/access/xloginsert.h` — `REGBUF_*` 标志定义

**最后更新**: 2026-07 | **适用版本**: PostgreSQL 16.x
