# HOT update

```sql
drop table if exists tb;
create table tb(a int);

insert into tb values (1);

update tb set a = 1;

select * from tb; -- 触发延迟更新 t_infomask

select lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_field3 as cid, t_ctid, t_infomask2, t_infomask, t_hoff from heap_page_items(get_raw_page('tb', 0));

vacuum tb;

select lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_field3 as cid, t_ctid, t_infomask2, t_infomask, t_hoff from heap_page_items(get_raw_page('tb', 0));
```

核心目标：消除由于 UPDATE 导致的索引膨胀。在非 HOT 更新中，即使不修改索引列，由于元组物理位置（ctid）变了，也必须在索引中插入新记录。

物理实现：当更新不涉及索引列且当前 Page 有足够空间时，新元组会被打上 HEAP_ONLY_TUPLE (0x8000) 标记，且不再建立新的索引条目。

链条跳转：旧元组标记为 HEAP_HOT_UPDATED (0x4000)，其 t_ctid 指向新元组。索引扫描时，先找到旧元组，再顺着 Page 内部的物理链条“跳”到新元组。

空间收割：通过“页内修剪”（Page Pruning），系统可以物理删除中间的死元组，并将索引指向的 ItemId 直接重定向（LP_REDIRECT）到最新的 ItemId，从而彻底斩断冗长的物理链条。