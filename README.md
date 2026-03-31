# PostgreSQL 源码学习笔记

## 项目介绍

这是一个关于 **PostgreSQL 数据库源代码** 的深入学习笔记项目。通过系统化的文档和代码分析，记录和分享 PostgreSQL 内部工作原理。

## 📚 内容结构

### 核心模块文档

- **[boot.md](./boot.md)** - PostgreSQL 启动过程分析
- **[acrh.md](./acrh.md)** - 架构设计与核心组件
- **[compile.md](./compile.md)** - 编译与构建过程
- **[memory.md](Storage/memory.md)** - 内存管理机制
- **[storage.md](Storage/storage.md)** - 存储管理概览
- **[code_dir.md](./code_dir.md)** - 源代码目录结构

### 专题目录

- **QueryProcess/** - 查询处理流程
- **Storage/** - 存储子系统详解
- **Transaction/** - 事务处理机制

## 🎯 学习重点

本项目涵盖以下 PostgreSQL 核心主题：

1. **架构设计** - 后端进程、通信机制等
2. **启动和初始化** - PostgreSQL 服务启动的各个阶段
3. **查询处理** - SQL 查询的解析、规划和执行
4. **事务管理** - ACID 特性的实现原理
5. **存储引擎** - 数据如何存储和检索
6. **内存管理** - 缓冲池、内存上下文的设计

## 📖 快速开始

### 推荐阅读顺序

0. 从 [compile](compile.md) 编译调试源码
1. 从 [code_dir.md](./code_dir.md) 了解源代码目录结构
2. 阅读 [boot.md](./boot.md) 理解启动过程
3. 查看 [acrh.md](./acrh.md) 学习整体架构
4. 深入各专题目录（QueryProcess、Transaction、Storage）

### 环境要求

- PostgreSQL 源代码
- Linux/Unix 开发环境
- 文本编辑器或 IDE

## 🔗 相关资源

- [PostgreSQL 官方文档](https://www.postgresql.org/docs/)
- [PostgreSQL 源代码仓库](https://github.com/postgres/postgres)
- [interdb](https://www.interdb.jp/pg/index.html)
- [postgres-internals](https://postgres-internals.cn/docs/chapter01/)
- [deepwiki.com](https://deepwiki.com/postgres/postgres/1-overview)


## 💡 使用建议

- 这些笔记最适合与 PostgreSQL 源代码一起阅读
- 建议搭配断点调试，更深入理解代码执行流程
- 欢迎提出建议和贡献改进

---

**维护者**: [Jason](https://github.com/zhougangjie)
