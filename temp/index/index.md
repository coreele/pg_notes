# INDEX

```sql
create table tb (a int, b text);
insert into tb select n, n || 'text_' from generate_series(1, 100000) as n;
create index idx on tb(a);
ANALYZE tb;
```
## index scan

```sql
explain select * from tb where a = 5432;
                               QUERY PLAN
-------------------------------------------------------------------------
 Index Scan using idx on tb  (cost=0.29..8.31 rows=1 width=13)
   Index Cond: (a = 5432)

```

## Index Only Scan

```sql
explain select a from tb where a = 5432;
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Index Only Scan using idx on tb  (cost=0.29..8.31 rows=1 width=4)
   Index Cond: (a = 5432)
```