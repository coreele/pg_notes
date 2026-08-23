# FSM Category

1. **Relation Fork机制**：main、fsm、vm三个fork；`_fsm`文件物理布局，FSM文件延迟创建（第一次vacuum / 第一次查找空闲页才生成），不是建表就生成。

```sql
CREATE EXTENSION IF NOT EXISTS pg_freespacemap;
CREATE EXTENSION IF NOT EXISTS pageinspect;

DROP TABLE IF EXISTS fsm_demo;
-- fillfactor=100，不预留update空间；关闭自动vacuum
CREATE TABLE fsm_demo (
    id int PRIMARY KEY,
    payload text
) WITH (fillfactor = 100, autovacuum_enabled = off);

-- 1.建表完毕，FSM fork尚未创建 fsm_bytes = 0
SELECT
    pg_relation_size('fsm_demo','main') AS main_bytes,
    pg_relation_size('fsm_demo','fsm')  AS fsm_bytes;

-- 插入500行，每条payload=140字节，控制恰好占满 10 个heap page
INSERT INTO fsm_demo
SELECT g, repeat('x',120) FROM generate_series(1, 500) g;

-- 查看heap总块数：预期 ~10
SELECT pg_relation_size('fsm_demo','main') / 8192 AS heap_total_blocks;

-- 2.INSERT触发第一次GetPageWithFreeSpace，FSM fork被创建
SELECT pg_relation_size('fsm_demo','fsm') / 8192 AS fsm_total_blocks;

-- FSM对外API：FSM预估空闲字节
SELECT blkno, avail AS fsm_est_free_bytes, avail/32 AS fsm_cat
FROM pg_freespace('fsm_demo')
ORDER BY blkno;

-- 3.对比：FSM预估空闲 VS heap page真实空闲（前12个heap块）
SELECT
    f.blkno,
    f.avail AS fsm_est_free_bytes,
    f.avail / 32 AS fsm_cat,
    (ph.upper - ph.lower)::int AS heap_real_free_bytes -- PageGetExactFreeSpace
FROM pg_freespace('fsm_demo') f
JOIN LATERAL page_header(get_raw_page('fsm_demo', f.blkno::int)) ph ON true
WHERE f.blkno < 12
ORDER BY f.blkno;

-- 4.查看FSM fork页内容
-- fsm blk0 = FSM树根页（内部节点全部255）
SELECT fsm_page_contents(get_raw_page('fsm_demo', 'fsm', 2));

-- 5.delete制造页内空洞：删除后面3页的数据，heap产生空闲，但FSM不变
DELETE FROM fsm_demo WHERE id < 350;

-- delete之后，FSM缓存仍然是旧值
SELECT max(avail) AS max_fsm_bytes_before_vacuum
FROM pg_freespace('fsm_demo');

-- 看heap真实空闲：后面几个块 heap_real_free_bytes 已经变大
SELECT
    f.blkno,
    f.avail AS fsm_est_free_bytes,
    (ph.upper - ph.lower)::int AS heap_real_free_bytes
FROM pg_freespace('fsm_demo') f
JOIN LATERAL page_header(get_raw_page('fsm_demo', f.blkno::int)) ph ON true
WHERE f.blkno <12
ORDER BY f.blkno;

-- 执行vacuum：扫描heap pages，批量刷新FSM树
VACUUM fsm_demo;

SELECT max(avail) AS max_fsm_bytes_after_vacuum
FROM pg_freespace('fsm_demo');

-- vacuum后叶子FSM页，128被替换为真实category
\x on
SELECT fsm_page_contents(get_raw_page('fsm_demo', 'fsm', 1));
\x off

-- 6.测试 RecordAndGetPageWithFreeSpace 就地修正FSM（不跑vacuum也可以修正单个slot）
-- 先删除再回滚，把FSM恢复到旧状态
BEGIN;
DELETE FROM fsm_demo WHERE id > 450;
ROLLBACK;

-- 现在FSM里blk0还是旧hint，heap blk0有少量空闲
-- 尝试插入，PG选中blk0，发现真实空间不足，就地修正FSM
INSERT INTO fsm_demo(id,payload) VALUES(9999, repeat('x',100));

-- blk0被修正，其余块依旧保留旧FSM值
SELECT blkno, avail AS fsm_est_free_bytes, avail/32 AS fsm_cat
FROM pg_freespace('fsm_demo')
WHERE blkno IN (0,1,2,3,4)
ORDER BY blkno;

```

2. **FSM Category档位机制**
   - `FSM_CATEGORIES=256`，1字节记录一个heap page空闲档位；`FSM_CAT_STEP = BLCKSZ / 256`（8K页下=32字节）。
   - 三个转换函数：
     - `fsm_space_avail_to_cat()`：真实空闲字节 → category档位
     - `fsm_space_needed_to_cat()`：需要多少字节 → 最小需要的category
     - `fsm_space_cat_to_avail()`：category → 对应最小空闲字节数
   - ⚠️关键点：FSM只存区间，**不存精确值**；255代表≥`MaxFSMRequestSize`。
3. FSM地址模型：`FSMAddress{level, logpageno}`，逻辑层号+逻辑页号，完成heap blockno ↔ FSM(level,slot)双向映射。
4. 工具扩展`contrib/pg_freespacemap`，`pg_freespace()`，用于调试观察FSM内容，实操验证理解。
