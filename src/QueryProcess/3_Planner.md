# Planner

参考文档: https://www.interdb.jp/pg/pgsql03/02.html

在 PostgreSQL 的逻辑层（Query Tree 阶段），最核心的逻辑算子主要有以下几类：

1. 扫描算子 (Scan / RangeTable) 
2. 过滤算子 (Filter / Quals) 
3. 连接算子 (Join) 
4. 投影算子 (Project / TargetList) 
5. 聚合算子 (Aggregate / Grouping) 
6. 排序算子 (Sort) 
7. 集合算子 (Set Operations) 

### 逻辑算子与物理算子的转换（核心对比）

FROM -> WHERE -> GROUP BY -> HAVING -> SELECT -> DISTINCT -> ORDER BY -> LIMIT

逻辑层只决定 **“要做什么”** ，而物理层（Planner 之后）决定 **“具体怎么做”**。

| 逻辑算子 (What) | 物理算子示例 (How) |
| --- | --- |
| **扫描 (Scan)** | `SeqScan`, `IndexScan`, `BitmapHeapScan` |
| **连接 (Join)** | `NestLoop`, `HashJoin`, `MergeJoin` |
| **聚合 (Agg)** | `HashAggregate` (哈希), `GroupAggregate` (排序后分组) |
| **去重 (Distinct)** | `Unique` (排序去重), `HashAggregate` (哈希去重) |

- 逻辑算子定意图
- 物理算子定实现
- 代价模型定优劣

## 函数调用基本逻辑

```cpp
pg_plan_queries
	pg_plan_query: commandType != CMD_UTILITY
		planner
			standard_planner: PlannerGlobal
				/* primary planning entry point (may recurse for subqueries) */
				root = subquery_planner(glob, parse, NULL, false, tuple_fraction);

				/* Select best Path and turn it into a Plan */
				final_rel = fetch_upper_rel(root, UPPERREL_FINAL, NULL);
				best_path = get_cheapest_fractional_path(final_rel, tuple_fraction);
				
				top_plan = create_plan(root, best_path);
```