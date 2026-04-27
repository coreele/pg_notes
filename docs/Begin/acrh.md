# Architecture

![](assets/architecture.png)

> https://medium.com/@reetesh043/ee5b24b52a30

![](assets/query.png)

## PG 内核全景:

- **控制面**：查询分析 => 优化器 => 执行器
- **数据面**：访问方法（Heap/Index）=> **Buffer Cache** => 物理磁盘
- **事务面**：**Lock Manager** => **WAL/CLOG** => **MVCC (Visible check)**
- **元数据面**：**Syscache (系统表缓存)** => Relcache (表定义缓存)
- **运行面**：**MemoryContext** => 信号量/共享内存 > 辅助进程

### **数据面 (Data Plane)：物理实体**

数据面负责处理所有与**字节、块、文件**相关的物理操作，核心目标是：**极速读写、持久存储**。

- **存储引擎（Storage Engine）**：管理数据在磁盘上的物理布局（Heap, B-Tree）
- **缓冲池（Shared Buffers）**：数据在内存中的镜像，是数据流转的中转站
- **物理辅助（FSM/VM）**：空闲空间映射（FSM）和可见性映射（VM），它们是数据页的“物理索引”
- **日志实体（WAL Segments）**：数据变化的物理流水账

### **控制面 (Control Plane)：逻辑流程**

控制面负责处理所有与**规则、状态、决策、同步**相关的逻辑操作，包含元数据、事务处理，以及支撑这些逻辑运行的底层基础设施。

**A. 决策与规则 (Decision & Schema)**

- **查询解析与优化（Optimizer）**：基于**元数据**和统计信息，制定数据流转的最优路径
- **安全与权限**：控制谁能接触数据面

**B. 状态与并发 (State & Concurrency)**

- **事务管理（XID/CLOG）**：维护事务的生命周期，标记数据的逻辑版本
- **多版本控制（MVCC）**：逻辑上的“时空分割”，确保不同事务看到不同的数据快照

**C. 运行支撑与底层同步（Runtime Infrastructure）**

- **锁管理器（Lock Manager）**：**重型锁**确保业务逻辑不冲突（如：禁止在插入时删表）
- **同步原语（LWLocks/Spinlocks）**：**轻量级锁**确保控制面在修改共享状态（如修改事务号、分配内存）时的物理原子性
- **内存上下文（MemoryContext）**：确保控制面在运行过程中，内存资源的分配和回收是合理的、不泄露的
