# INDEX

```sql
create table tb (a int, b text);
insert into tb select n, n || '_text' from generate_series(1, 100000) as n;
create index idx on tb(a);
ANALYZE tb;
```
## index scan

```sql
explain select * from tb where a = 5432;
                          QUERY PLAN                           
---------------------------------------------------------------
 Index Scan using idx on tb  (cost=0.29..8.31 rows=1 width=14)
   Index Cond: (a = 5432)

```

### width = 14?

```sql
select attname, avg_width from pg_stats where tablename='tb';

select avg(length(b)) from tb;
```

## Index Only Scan

```sql
explain select a from tb where a = 5432;
                            QUERY PLAN                             
-------------------------------------------------------------------
 Index Only Scan using idx on tb  (cost=0.29..8.31 rows=1 width=4)
   Index Cond: (a = 5432)
```
