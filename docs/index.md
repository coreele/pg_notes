# Overview

PostgreSQL 内部机制学习笔记。侧重底层实现原理，配合源码调试记录。

---

## 📚 基础篇

- [整体架构](Begin/acrh.md) - 进程模型、共享内存与 IPC 通信
- [编译与调试](Begin/compile.md) - 环境搭建与 LLDB/GDB 调试技巧
- [目录结构](Begin/code_dir.md) - 源码树概览与核心模块定位
- [启动流程](Begin/boot.md) - Postmaster 到 Backend 进程的生命周期

## ⚙️ 核心机制

- [查询执行](QueryProcess/0_Overview.md) - Parser, Planner, Executor 全流程解析
- [存储引擎](Storage/page.md) - Buffer Pool、Heap Table 与页面布局
- [内存管理](Utils/mmgr_0_overview.md) - MemoryContext 与 AllocSet 实现细节
- [事务系统](Transaction/trans.md) - MVCC、XID 分配与 WAL 日志机制

## 🛠 阅读建议

1. **run**：参考 [编译文档](Begin/compile.md) 本地构建 PG，学会 attach 进程调试。
2. **code**：笔记只是线索，核心逻辑请以 `src/backend` 下的 C 代码为准。
3. **debug**：建议通过 `gdb` 断点观察关键结构体（如 `ProcessUtility`, `ExecScan`）的运行时状态。

## 🔗 参考资料

- [PostgreSQL Internals (interdb.jp)](https://www.interdb.jp/pg/index.html)
- [PostgreSQL Source Code](https://github.com/postgres/postgres)
- [The Internals of PostgreSQL (book)](http://www.interdb.jp/pg/)

---

**Maintainer**: [coreele](https://github.com/coreele/pg_notes)
