# FSM（Free‑Space Map）源码学习核心主题

源码位置：

- `src/backend/storage/freespace/freespace.c`（对外入口、高层树逻辑）
- `src/backend/storage/freespace/fsmpage.c`（单FSM页内部二叉堆实现）
- `src/include/storage/fsm_internals.h`（内部结构体、宏定义）
- `src/backend/storage/freespace/README`（官方设计文档必读）

> FSM核心目标：插入元组时快速找到有足够空闲空间的heap page，避免扫描全表；**记录的是档位（category）不是精确字节数**，采用多叉最大堆树结构，独立fork文件`xxx_fsm`。
