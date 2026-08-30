# Overview

PostgreSQL 内核学习笔记，目录镜像 `src/backend/` 源码结构；跨模块调用链见 `traces/`。

---

## 快速入口

- [整体架构](meta/00_arch.md) — 进程模型、共享内存与 IPC
- [编译与调试](meta/02_compile.md) — 环境搭建与 GDB/LLDB
- [源码目录](meta/01_code.md) — `src/backend/` 模块导览
- [启动流程](meta/03_boot.md) — Postmaster → Backend 生命周期

## 核心模块

- [查询全链路](traces/00_query_overview.md) — tcop → parser → optimizer → executor
- [页面布局](backend/storage/page/01_page_layout.md) — Heap Page
- [事务 / MVCC](backend/access/transam/01_overview.md) — XID、WAL、可见性
- [内存管理](backend/utils/mmgr/01_overview.md) — MemoryContext

## 阅读建议

1. **run**：参考 [编译文档](meta/02_compile.md) 本地构建 PG，学会 attach 进程调试。
2. **code**：笔记只是线索，核心逻辑以 `src/backend` 下 C 代码为准。
3. **debug**：通过断点观察关键结构体（如 `ProcessUtility`、`ExecScan`）的运行时状态。

## 参考资料

- [PostgreSQL Internals (interdb.jp)](https://www.interdb.jp/pg/index.html)
- [PostgreSQL Source Code](https://github.com/postgres/postgres)

---

**Maintainer**: [coreele](https://github.com/coreele/pgnote)
