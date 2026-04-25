-- restart, checkpoint_lsn = redo_lsn
SELECT 
    checkpoint_lsn,
    redo_lsn,
    redo_wal_file,
    timeline_id,
    checkpoint_time
FROM pg_control_checkpoint();

-- checkpoint_lsn < current_lsn
SELECT pg_current_wal_lsn() AS lsn;

SELECT pg_size_pretty(pg_current_wal_lsn() - redo_lsn) AS startup_overhead
FROM pg_control_checkpoint();

INSERT INTO wal_test VALUES (1, 'Hello WAL');

SELECT pg_current_wal_lsn() AS lsn;

SELECT 
    checkpoint_lsn,
    redo_lsn,
    redo_wal_file,
    timeline_id,
    checkpoint_time
FROM pg_control_checkpoint();

-- 通过wal_inspect插件查看log记录
SELECT 
    *
FROM pg_get_wal_records_info('0/2E9DD78', pg_current_wal_lsn());