# INDEX(`nbtree`)

```sql
drop table if exists tb;
create table tb (a int, b bigint);
insert into tb select n, n from generate_series(1, 100000) as n;
create index idx on tb(a);
ANALYZE tb;

explain select * from tb where a = 5432;
                          QUERY PLAN
---------------------------------------------------------------
 Index Scan using idx on tb  (cost=0.29..8.31 rows=1 width=12)
   Index Cond: (a = 5432)
```

## index file

```sql
select pg_relation_filepath('idx');
 pg_relation_filepath
----------------------
 base/5/99591
```

## index page type

1. 元数据页（Meta Page）

- 块号固定为 0（BTREE_METAPAGE = 0）
- 标志：BTP_META
- 内容：BTMetaPageData，记录：
  - btm_root / btm_level：真正根页
  - btm_fastroot / btm_fastlevel：快根（fast root）
  - 版本号、deduplication 相关字段等
- 不参与键空间搜索，只提供根位置等全局信息

2. 根页（Root Page）

- 标志：BTP_ROOT
- 可以是叶根（BTP_ROOT | BTP_LEAF，树只有一层）或内根（仅 BTP_ROOT）
- 无

3. 叶页（Leaf Page）

- 标志：`BTP_LEAF`，`btpo_level == 0`
- 存索引键 + 堆 TID（指向被索引表行）
- 非最右叶页：第 1 项为 high key（上界），数据从第 2 项起
- 最右叶页：无 high key（隐式正无穷），数据从第 1 项起

4. 内页 / 非叶页（Internal / Non-leaf Page）

- 无 `BTP_LEAF`，`btpo_level > 0`
- 存 downlink（子页块号）+ 边界键（pivot tuple）
- 每项的键是子页键空间的严格下界；high key 是最后一项的上界
- 第一项逻辑下界为负无穷

层级编号从叶层 0 向上递增，根为 `树高 - 1`。

## index page inspect

```sql
select * from bt_page_items('idx', 1) limit 5;
 itemoffset | ctid  | itemlen | nulls | vars |          data           | dead | htid  | tids
------------+-------+---------+-------+------+-------------------------+------+-------+------
          1 | (1,1) |      16 | f     | f    | 6f 01 00 00 00 00 00 00 |      |       |
          2 | (0,1) |      16 | f     | f    | 01 00 00 00 00 00 00 00 | f    | (0,1) |
          3 | (0,2) |      16 | f     | f    | 02 00 00 00 00 00 00 00 | f    | (0,2) |
          4 | (0,3) |      16 | f     | f    | 03 00 00 00 00 00 00 00 | f    | (0,3) |
          5 | (0,4) |      16 | f     | f    | 04 00 00 00 00 00 00 00 | f    | (0,4) |

select itemoffset, ctid, itemlen, nulls, vars, bt_getitem(data) AS idx_key, dead, htid, tids from bt_page_items('idx', 1) limit 5;
```
