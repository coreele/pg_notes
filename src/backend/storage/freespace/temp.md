## 一、基础概念与物理存储（先搞懂“FSM是什么”）

1. **Relation Fork机制**：main、fsm、vm三个fork；`_fsm`文件物理布局，FSM文件延迟创建（第一次vacuum / 第一次查找空闲页才生成），不是建表就生成。
2. **FSM Category档位机制（最核心基础）**
   - `FSM_CATEGORIES=256`，1字节记录一个heap page空闲档位；`FSM_CAT_STEP = BLCKSZ / 256`（8K页下=32字节）。
   - 三个转换函数：
     - `fsm_space_avail_to_cat()`：真实空闲字节 → category档位
     - `fsm_space_needed_to_cat()`：需要多少字节 → 最小需要的category
     - `fsm_space_cat_to_avail()`：category → 对应最小空闲字节数
   - ⚠️关键点：FSM只存区间，**不存精确值**；255代表≥`MaxFSMRequestSize`。
3. FSM地址模型：`FSMAddress{level, logpageno}`，逻辑层号+逻辑页号，完成heap blockno ↔ FSM(level,slot)双向映射。
4. 工具扩展`contrib/pg_freespacemap`，`pg_freespace()`，用于调试观察FSM内容，实操验证理解。

## 二、FSM页内部：单页的二叉最大堆（fsmpage.c）

> 每一个FSM Page内部是一颗**完全二叉堆（最大堆）**，父节点存子节点最大值，根为本FSM页内最大空闲档位。

1. `FSMPage`结构体：`fp_nodes[]`数组存放堆节点；`fp_next_slot`（轮询hint，重要优化，避免每次从根遍历）。
2. `SlotsPerFSMPage`：一页最多可以管理多少个叶子slot（默认1626）。
3. **核心查找函数 `fsm_search_avail()`**
   - 搜索逻辑：优先从`fp_next_slot`提示位置开始，不满足向上回溯父节点，向下找到叶子slot；根节点不满足直接返回无可用slot。
   - `fp_next_slot`的作用、更新、wrap‑around回绕逻辑，并发下只是hint，不保证准确。
4. 堆更新：`fsm_set_avail()`更新一个叶子slot，递归向上更新父节点最大值；堆维护，子节点变化向上传播。

> 重点：FSM页内部是堆；上层FSM页的叶子，是下层FSM页，而不是heap page。

## 三、跨页多层FSM树（freespace.c，全局树）

- FSM是**多层树**：叶子层（level=FSM_BOTTOM_LEVEL）slot对应heap page；上层每一个slot，对应下层一个完整FSM page，保存该FSM page的最大值。
- 默认BLCKSZ=8K时，3层树就可以管理2^32个heap block，覆盖PG最大表大小。

1. `fsm_search()`：高层树搜索入口；从根向下遍历多层FSM树，找到满足min_cat的heap block。
2. `fsm_update_recursive()`：heap page空闲空间变化，递归更新多层FSM树上所有受影响的父节点。
3. `fsm_extend()`：FSM文件扩展；当heap page变多，FSM需要新增FSM block。
4. heap blockno 到FSM的`level、logpageno、slot`的换算公式，读懂`fsm_get_*`系列宏。

## 四、对外调用入口（heap层如何调用FSM）

这部分是FSM和执行层的边界，理解什么时候会读写FSM：

1. `GetPageWithFreeSpace(rel, spaceNeeded)`：找一个有足够空闲空间的page，返回blockno，找不到返回InvalidBlockNumber，上层就扩展新page。
2. `RecordPageWithFreeSpace(rel, heapBlk, spaceAvail)`：把heap page当前空闲空间上报给FSM。
3. `RecordAndGetPageWithFreeSpace()`：组合接口：旧page使用后空闲变少，更新FSM，再找下一个可用页（update + search）。
4. `GetRecordedFreeSpace()`：读取FSM记录的该页的预估空闲。

> 关键点：**普通insert/update修改heap page之后，不会立刻同步更新FSM！**
> FSM不会实时同步heap page真实空闲；heap页本地pd_free_space变化不会自动写FSM，只有两种场景更新FSM：
> ① VACUUM扫描页面，调用`RecordPageWithFreeSpace`更新；
> ② 拿到page插入元组后，调用`RecordAndGetPageWithFreeSpace`把使用后剩余空间写回FSM。

## 五、Vacuum与FSM交互（高频面试点，必看）

1. VACUUM如何重建/更新FSM：`FreeSpaceMapVacuum()`，`fsm_vacuum_page()`。
2. 重要坑：**FSM会遗忘空闲页**。FSM文件只记录有限数量页面；当大量页面释放空闲，如果FSM放不下，部分空闲页不会被记录，直到下一次vacuum，这些空闲空间不会被复用，引发表膨胀。
3. TRUNCATE时：`FreeSpaceMapPrepareTruncateRel()`截断FSM文件。
4. FSM和VM（Visibility Map）对比：两者都是独立fork，职责完全不同；FSM记录空闲空间，VM记录页面是否全部可见。

## 六、WAL与崩溃恢复

1. `XLogRecordPageWithFreeSpace()`，FSM更新是否写WAL？

> PG设计：FSM不做完整WAL保护；崩溃后FSM可能失真。重启后FSM里的信息可能是旧的，**下一次vacuum会修复FSM**。理解这个设计取舍，为什么不持久化保护FSM，这是很多人理解盲区。

## 七、并发、锁与性能细节

1. Buffer锁：读FSM page用shared锁，更新FSM page用exclusive锁。
2. `fp_next_slot`只是提示，无锁保护，允许重复扫描同一个page，牺牲一点点效率换无锁高并发。
3. FSM是提示性结构，允许过时；即使FSM说有足够空间，拿到heap page后仍要检查真实pd_free_space，如果实际不够，丢弃该页，调用`RecordAndGetPageWithFreeSpace`再重新找。

> 流程：FSM返回blkno → 打开heap page → 检查真实空闲，如果不够，回写FSM该页的真实档位，重新搜索。

## 八、常见bug、现象、踩坑（结合源码理解）

1. vacuum不跑，大量空闲空间，但FSM不知道，表持续膨胀。
2. FSM记录的空闲 > 真实页面空闲：拿到page才发现放不下元组，重新查找。
3. 大量delete后，不vacuum，insert不会复用空闲页。
4. pg_freespacemap看到的值和heap page真实pd_free_space不一致。

## 九、阅读路径建议（实操顺序）

1. 读`freespace/README`官方文档。
2. 搞懂category转换，把3个转换函数逻辑手写一遍。
3. 读`fsmpage.c`：单页最大堆，`fsm_search_avail`、`fsm_set_avail`。
4. 读`freespace.c`多层树，理解blockno到FSM地址映射，`fsm_search`、`fsm_update_recursive`。
5. 看heap层调用入口，理解什么时候调用FSM。
6. 看vacuum如何更新FSM，理解FSM数据为什么会过时，崩溃恢复行为。
7. 用pg_freespacemap做小实验，建表、delete、vacuum，观察FSM数值变化。

如果你需要，我可以帮你整理一份极简的调用流程图（ASCII文本），把“insert元组调用FSM的完整调用链路”画出来。
