# INDEX(`nbtree`)

```sql
drop table if exists tb;
create table tb (a int, b bigint);
insert into tb select n, n from generate_series(1, 100000) as n;
ANALYZE tb;
```

## sequence scan

```sql
explain select * from tb where a = 5432;
                      QUERY PLAN                      
------------------------------------------------------
 Seq Scan on tb  (cost=0.00..1791.00 rows=1 width=12)
   Filter: (a = 5432)
```

## index scan

```sql
create index idx on tb(a);
ANALYZE tb;

explain select * from tb where a = 5432;
                          QUERY PLAN                           
---------------------------------------------------------------
 Index Scan using idx on tb  (cost=0.29..8.31 rows=1 width=12)
   Index Cond: (a = 5432)
```

### width = 15?

```sql
select attname, avg_width from pg_stats where tablename='tb';
 attname | avg_width 
---------+-----------
 a       |         4
 b       |         8
```

## Index Only Scan

```sql
explain select a from tb where a = 5432;
                            QUERY PLAN                             
-------------------------------------------------------------------
 Index Only Scan using idx on tb  (cost=0.29..4.31 rows=1 width=4)
   Index Cond: (a = 5432)
```
