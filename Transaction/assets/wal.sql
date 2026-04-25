create extension pg_walinspect;

SELECT pg_current_wal_lsn() AS lsn;

INSERT INTO tb VALUES (1);

SELECT pg_current_wal_lsn() AS lsn;

SELECT 
    *
FROM pg_get_wal_records_info('0/2E9DD78', pg_current_wal_lsn());