# Mini-Transaction (临界区机制)

## 问题

修改 shared buffer 和写入 WAL 之间存在**竞态窗口**：如果修改了 buffer 但在写入 WAL 之前发生了错误或崩溃，buffer 包含了未记录到 WAL 的脏数据。如果 buffer 稍后被刷盘，这些更改将丢失。

```
❌ 非原子操作的风险:

  修改 buffer ──→ 崩溃/错误 ──→ buffer 有脏数据但无 WAL 记录
                                              │
                                        Buffer 刷盘 ──→ 数据永久丢失
```

**解决方案**: 临界区 (Critical Section) — 将 buffer 修改 + WAL 插入包装为原子操作。临界区内的任何错误导致 **PANIC** (实例立即关闭)，防止不一致状态。

---

## 1. 核心实现

```c
// src/include/miscadmin.h (简化版)

// 每个进程的临界区计数 (嵌套支持)
extern __thread int critSecCount;

// 进入临界区
#define START_CRIT_SECTION()  \
    do { \
        InterruptHoldoffCount++;   // ① 禁止中断 (die, query cancel 等)
        critSecCount++;            // ② 递增临界区计数
        // 如果 pending 中断被排队的，触发 PANIC
        if (INTERRUPTS_PENDING_CONDITION()) \
            PANIC("...");  \
    } while(0)

// 退出临界区
#define END_CRIT_SECTION()  \
    do { \
        critSecCount--;            // ① 递减临界区计数
        InterruptHoldoffCount--;   // ② 允许中断
        // 如果在临界区外有待处理的中断，现在处理
        if (InterruptHoldoffCount == 0 && INTERRUPTS_PENDING_CONDITION()) \
            ProcessInterrupts();   // ③ 处理延迟中断
    } while(0)
```

### 关键设计要点

| 机制 | 说明 |
|------|------|
| **中断屏蔽** | 临界区禁止 die/query cancel 等异步中断，防止缓冲区处在不一致状态 |
| **PANIC 保证** | 临界区内任何错误 (语法错误、磁盘满等) → PANIC → 实例重启 → 恢复重放 WAL |
| **嵌套支持** | `critSecCount` 作为计数器支持嵌套临界区 |
| **进入前检查** | 进入时如有 pending 中断 → PANIC，防止带着未处理错误进入临界区 |

---

## 2. 为什么需要 PANIC？

考虑以下场景：

```
START_CRIT_SECTION();
  MarkBufferDirty(buffer);                  // ① buffer 标记为脏
  // ...
  XLogBeginInsert();
  XLogRegisterBuffer(0, buffer, ...);
  XLogRegisterData(&xlrec, sizeof(xlrec));

  // ② XLogInsert 内部需要分配空间，但磁盘满！
  XLogInsert(RM_HEAP_ID, XLOG_HEAP_INSERT);  // ❌ ERROR: 磁盘满
  // 此时 buffer 已脏但没有 WAL 记录
END_CRIT_SECTION();
```

如果这里抛出普通 ERROR (而非 PANIC)：
- Buffer 已被标记为脏，包含未记录到 WAL 的修改
- 事务回滚，但 buffer 没有被恢复
- checkpointer 稍后刷出此 buffer → **数据损坏**

PANIC 处理：
- 实例立即终止
- 崩溃恢复启动，从最后一个 checkpoint 重放 WAL
- 由于没有成功写入 WAL，buffer 修改被丢弃
- **数据一致性得到保证**

---

## 3. 标准使用模式

```c
// 典型的 heap insert 中的 MTR 模式:

void heap_insert(Relation rel, HeapTuple tup, ...) {
    Buffer buffer = ReadBuffer(rel, P_NEW);          // ① Pin 页面
    LockBuffer(buffer, BUFFER_LOCK_EXCLUSIVE);       // ② 独占锁

    // === 临界区开始 ===
    START_CRIT_SECTION();

    MarkBufferDirty(buffer);                          // ③ 标记脏 (必须在写 WAL 前)

    // ④ 修改 buffer
    PageAddItem(page, (Item) tup->t_data, ...);

    // ⑤ 构造 WAL
    XLogBeginInsert();
    XLogRegisterBuffer(0, buffer, REGBUF_STANDARD);
    XLogRegisterData(&xlrec, SizeOfHeapInsert);
    XLogRegisterBufData(0, tup->t_data, tup->t_len);

    // ⑥ 插入 WAL 并更新页面 LSN
    recptr = XLogInsert(RM_HEAP_ID, XLOG_HEAP_INSERT);
    PageSetLSN(page, recptr);

    // === 临界区结束 ===
    END_CRIT_SECTION();

    UnlockReleaseBuffer(buffer);                      // ⑦ 解锁
}
```

### 规则清单

在临界区内的操作顺序是**严格约束**的：

| 步骤 | 操作 | 说明 |
|------|------|------|
| ① | Pin + Lock | 临界区外完成 (锁可能等待，不应在临界区内) |
| ② | `START_CRIT_SECTION()` | 进入临界区，禁止中断 |
| ③ | `MarkBufferDirty()` | **必须**在 `XLogInsert` 之前 (确保 WAL 刷盘逻辑正确) |
| ④ | 修改 buffer | 任意修改 (PageAddItem, 更新元组头等) |
| ⑤ | WAL 注册 | `XLogBeginInsert` + `XLogRegister*` |
| ⑥ | WAL 插入 + LSN | `XLogInsert` + `PageSetLSN` |
| ⑦ | `END_CRIT_SECTION()` | 退出临界区，恢复中断处理 |
| ⑧ | Unlock + Unpin | 临界区外完成 |

---

## 4. 与 InnoDB MTR 的对比

InnoDB 的 Mini-Transaction (MTR) 有显式的 `mtr_t` 结构体，管理锁、redo log 记录、脏页列表。

PostgreSQL 的 "MTR" 更轻量，没有独立的 struct，而是直接使用：

| 概念 | InnoDB MTR | PostgreSQL 等效 |
|------|-----------|----------------|
| **原子单元** | `mtr_t` 结构体 | `START/END_CRIT_SECTION()` 宏对 |
| **页面修改** | `mtr_memo_push` (记录锁/页面) | 显式的 `ReadBuffer` + `LockBuffer` |
| **日志记录** | `mlog_write_ulint` / `mtr_commit()` | `XLogBeginInsert` + `XLogRegister*` + `XLogInsert` |
| **脏页跟踪** | `buf_block_dbg_add_level` | `MarkBufferDirty()` |
| **LSN 更新** | `mtr_commit()` 内部 | 显式 `PageSetLSN()` |
| **崩溃恢复** | LSN + doublewrite | LSN + FPW |
| **嵌套** | 不支持 | 支持 (`critSecCount` 计数) |
| **错误处理** | `mtr_t::error_state` | PANIC |

### 关键区别

1. **显式 vs 隐式**: InnoDB 使用显式的 `mtr_t` 对象；PG 使用宏和全局变量 (`critSecCount`)
2. **提交语义**: InnoDB 的 `mtr_commit()` 同时完成 WAL 写入 + 页面解锁 + LSN 更新；PG 中这些是分开的显式调用
3. **PANIC 策略**: PG 更激进 — 临界区内任何错误 = PANIC。InnoDB 的 MTR 在某些错误后可以继续
4. **一个临界区 ≠ 一条 WAL 记录**: PG 中一个临界区可以包含多次 `XLogInsert` (如 B-tree 分裂可能需要多步操作)

---

## 5. B-Tree 分裂：多步 MTR 示例

B-Tree 分裂是典型的需要**多次 WAL 插入**但**一个临界区**的场景：

```c
// src/backend/access/nbtree/nbtinsert.c (简化)

void _bt_split(...) {
    // === 准备工作 (临界区外) ===
    Buffer rbuf = ReadBuffer(rel, P_NEW);
    LockBuffer(rbuf, BUFFER_LOCK_EXCLUSIVE);

    Buffer lbuf = ReadBuffer(rel, left_blkno);
    LockBuffer(lbuf, BUFFER_LOCK_EXCLUSIVE);

    // === 第一步: 分配新页面并移动元组 ===
    START_CRIT_SECTION();
    MarkBufferDirty(rbuf);
    MarkBufferDirty(lbuf);

    // 移动元组从左页到右页
    PageAddItem(rightpage, ...);

    // 写 WAL (分配新页面)
    XLogBeginInsert();
    XLogRegisterBuffer(0, lbuf, REGBUF_STANDARD);
    XLogRegisterBuffer(1, rbuf, REGBUF_STANDARD | REGBUF_WILL_INIT);
    XLogRegisterBufData(1, tuples, len);
    recptr = XLogInsert(RM_BTREE_ID, XLOG_BTREE_SPLIT);
    PageSetLSN(BufferGetPage(lbuf), recptr);
    PageSetLSN(BufferGetPage(rbuf), recptr);
    END_CRIT_SECTION();

    // === 第二步: 将键插入父页 (单独的临界区，需要获取父页锁) ===
    Buffer pbuf = _bt_getstackbuf(rel, stack);
    LockBuffer(pbuf, BUFFER_LOCK_EXCLUSIVE);

    START_CRIT_SECTION();
    MarkBufferDirty(pbuf);

    _bt_insert_parent(rel, lbuf, rbuf, stack, ...);

    XLogBeginInsert();
    XLogRegisterBuffer(0, pbuf, REGBUF_STANDARD);
    XLogRegisterBuffer(1, lbuf, REGBUF_STANDARD);
    XLogRegisterBuffer(2, rbuf, REGBUF_STANDARD);
    recptr = XLogInsert(RM_BTREE_ID, XLOG_BTREE_INSERT_PARENT);
    PageSetLSN(BufferGetPage(pbuf), recptr);
    PageSetLSN(BufferGetPage(lbuf), recptr);
    PageSetLSN(BufferGetPage(rbuf), recptr);
    END_CRIT_SECTION();

    UnlockReleaseBuffer(rbuf);
    UnlockReleaseBuffer(lbuf);
    UnlockReleaseBuffer(pbuf);
}
```

**为什么分两步？**

B-Tree 分裂的中间状态 (新页面已分配但父键未插入) 是**自洽的**。如果崩溃发生在这两步之间：
1. 第一步的 WAL 已写入：新页面已分配，元组已移动，标志 `BTP_INCOMPLETE_SPLIT` 已设置
2. 恢复时：重放第一步，页面进入 "不完整分裂" 状态
3. 后续插入操作遇到不完整分裂的页面时，会完成分裂

这样避免了需要同时锁住子页和父页的问题。

---

## 6. REGBUF_IN_CRIT_SECTION 标志 — 自动配对的尝试

在 PG 16 中引入了 `REGBUF_IN_CRIT_SECTION` 标志，尝试自动化部分临界区管理：

```c
// XLogRegisterBuffer 内部:
if (flags & REGBUF_IN_CRIT_SECTION) {
    // 自动 START_CRIT_SECTION
    buffer->begins_critical_section = true;
    START_CRIT_SECTION();
}

// XLogInsert 内部:
for (block_id = 0; ...) {
    if (registered_buffers[block_id].begins_critical_section) {
        END_CRIT_SECTION();
        critSecCount -= buffer_inside_count;  // 嵌套临界区的重置
    }
}
```

此标志的目的是允许更粒度的 PANIC，仅在 buffer 修改后、WAL 插入失败时 PANIC，而不是在注册阶段就 PANIC。目前尚未被广泛采用。

---

## 7. 临界区与 Buffer 锁的交互

```
临界区 & Buffer 锁的层次关系:

  获取 Buffer 锁 (LockBuffer)      ← 临界区外
    ┌─────────────────────────────┐
    │  START_CRIT_SECTION()       │
    │         MarkBufferDirty()   │
    │         修改 buffer          │
    │         XLogBeginInsert()   │
    │         XLogRegister*       │
    │         XLogInsert()        │
    │         PageSetLSN()        │
    │  END_CRIT_SECTION()         │
    └─────────────────────────────┘
  释放 Buffer 锁 (UnlockReleaseBuffer) ← 临界区外
```

- **锁必须在临界区外获取**：获取锁可能需要等待，在临界区内等待会导致 PANIC
- **锁在临界区结束后释放**：确保在 WAL 写入完成前，页内容对其他后端可见
- **临界区内持有锁**：这个约束本身天然成立，因为锁是在临界区外获取的

---

## 8. 临界区与 XLogBeginInsert 的关系

`XLogBeginInsert` 重置 WAL 记录构造状态。**一个临界区可以包含多次 XLogBeginInsert/XLogInsert**，但**不能跨越临界区**：

```c
// ❌ 错误: XLogBeginInsert 跨越临界区
START_CRIT_SECTION();
XLogBeginInsert();
END_CRIT_SECTION();
// ... (另一个临界区修改另一个 buffer)
START_CRIT_SECTION();
XLogRegisterBuffer(0, buf, ...);  // ❌ buf 已不在临界区内持有
XLogInsert(...);
END_CRIT_SECTION();

// ✅ 正确: 每次 XLogBeginInsert -> XLogInsert 在同一临界区内
START_CRIT_SECTION();
  XLogBeginInsert();
  XLogRegisterBuffer(0, buf1, ...);
  XLogInsert(...);                   // 第一条 WAL
END_CRIT_SECTION();

START_CRIT_SECTION();
  XLogBeginInsert();
  XLogRegisterBuffer(0, buf2, ...);
  XLogInsert(...);                   // 第二条 WAL
END_CRIT_SECTION();
```

---

## 9. 检查清单

编写新的 WAL 记录代码时，确保：

- [ ] `START_CRIT_SECTION` 在 buffer 修改之前
- [ ] `MarkBufferDirty` 在 `XLogInsert` 之前
- [ ] `PageSetLSN` 在 `XLogInsert` 之后
- [ ] `XLogBeginInsert` / `XLogRegister*` / `XLogInsert` 在同一临界区内
- [ ] 临界区外处理所有可能的错误 (如检查页面是否有足够空间)
- [ ] 临界区内不等待 buffer 锁 (锁在临界区外获取)
- [ ] 所有被修改的 buffer 都注册到 WAL 记录中
- [ ] `REGBUF_WILL_INIT` 用于完全重新初始化的页面
- [ ] 中间状态是自洽的 (对多步操作)

---

**关键源码文件**:
- `src/include/miscadmin.h` — `START_CRIT_SECTION` / `END_CRIT_SECTION` 宏定义
- `src/backend/access/transam/xloginsert.c` — WAL 插入与临界区交互
- `src/backend/access/heap/heapam_handler.c` — heap WAL 记录示例
- `src/backend/access/nbtree/nbtinsert.c` — B-tree 多步临界区示例

**最后更新**: 2026-07 | **适用版本**: PostgreSQL 16.x
