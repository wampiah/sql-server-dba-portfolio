/* SQL Server 2019 only. Run ONE complete file in SSMS on ONE instance.
   Do not use Registered Servers / multi-server execution.
   Read README.md first. Run as an authorised sysadmin.
   Edit @DatabaseName and @ExpectedServer; record the pre-change settings.
   This script does not kill sessions, force rollback, or change database user access.
*/
USE [master];
SET NOCOUNT ON;
DECLARE @DatabaseName sysname = N'REPLACE_DATABASE_NAME';
DECLARE @ExpectedServer sysname = N'REPLACE_SERVER_NAME'; -- match SERVERPROPERTY('ServerName')

IF CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 15
    THROW 51000, 'This pack targets SQL Server 2019 (major version 15) only.', 1;
IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) <> 1
    THROW 51001, 'Run through an authorised sysadmin account.', 1;
IF @ExpectedServer = N'REPLACE_SERVER_NAME'
   OR @ExpectedServer <> CONVERT(sysname, SERVERPROPERTY('ServerName'))
    THROW 51002, 'Set @ExpectedServer to this instance ServerName after verifying the target.', 1;
IF @DatabaseName = N'REPLACE_DATABASE_NAME' OR DB_ID(@DatabaseName) IS NULL
    THROW 51003, 'Set @DatabaseName to an existing user database.', 1;
DECLARE @DatabaseId int = DB_ID(@DatabaseName);
IF @DatabaseId <= 4
    THROW 51004, 'System databases are outside the scope of this pack.', 1;
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = @DatabaseId AND source_database_id IS NOT NULL)
    THROW 51005, 'Database snapshots are outside the scope of this pack.', 1;
IF @@TRANCOUNT <> 0
    THROW 51006, 'Do not run this script inside a transaction.', 1;

SELECT CONVERT(sysname, SERVERPROPERTY('ServerName')) AS server_name,
       SYSUTCDATETIME() AS captured_at_utc, name,
       state_desc, user_access_desc, is_read_only,
       is_read_committed_snapshot_on,
       snapshot_isolation_state_desc,
       is_accelerated_database_recovery_on
FROM sys.databases WHERE database_id = @DatabaseId;

-- Point-in-time output only. Save timestamped samples for trend comparisons.
-- Query Store / Extended Events / application telemetry provide historical evidence.

-- Traditional tempdb version store attributable to the target database.
SELECT SYSUTCDATETIME() AS captured_at_utc, database_id,
       reserved_page_count, reserved_space_kb / 1024.0 AS tempdb_version_store_mb
FROM sys.dm_tran_version_store_space_usage WHERE database_id = @DatabaseId;

-- PVS: this metric is OFF-ROW storage, not total space for all in-row versions.
SELECT SYSUTCDATETIME() AS captured_at_utc, database_id,
       persistent_version_store_size_kb / 1024.0 AS pvs_offrow_mb
FROM sys.dm_tran_persistent_version_store_stats WHERE database_id = @DatabaseId;

-- Instance-wide snapshot/versioning transactions: the DMV has no database_id.
-- Existing SNAPSHOT users can retain versions even though SI is outside this rollout.
-- Use the following target transaction list to help correlate; do not assume all
-- rows here belong to the selected database. is_snapshot=0 can include RCSI readers.
SELECT SYSUTCDATETIME() AS captured_at_utc, a.session_id, a.transaction_id,
       a.is_snapshot, a.elapsed_time_seconds,
       a.max_version_chain_traversed, a.average_version_chain_traversed,
       s.login_name, s.host_name, s.program_name
FROM sys.dm_tran_active_snapshot_database_transactions AS a
LEFT JOIN sys.dm_exec_sessions AS s ON s.session_id = a.session_id
ORDER BY a.elapsed_time_seconds DESC;

SELECT dt.transaction_id, st.session_id, at.transaction_begin_time,
       dt.database_transaction_log_bytes_used,
       dt.database_transaction_log_bytes_reserved
FROM sys.dm_tran_database_transactions AS dt
LEFT JOIN sys.dm_tran_session_transactions AS st ON st.transaction_id = dt.transaction_id
LEFT JOIN sys.dm_tran_active_transactions AS at ON at.transaction_id = dt.transaction_id
WHERE dt.database_id = @DatabaseId
ORDER BY at.transaction_begin_time;

-- Active target requests and their blockers; SQL text may contain application data.
SELECT SYSUTCDATETIME() AS captured_at_utc, r.session_id,
       r.blocking_session_id, r.status, r.command, r.wait_type,
       r.wait_time AS current_wait_ms, r.total_elapsed_time AS elapsed_ms,
       r.cpu_time AS cpu_ms, r.logical_reads, r.writes,
       s.host_name, s.program_name, t.text AS batch_text,
       bs.host_name AS blocker_host, bs.program_name AS blocker_program,
       bs.open_transaction_count AS blocker_open_transactions
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
LEFT JOIN sys.dm_exec_sessions AS bs ON bs.session_id = r.blocking_session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.database_id = @DatabaseId AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;

DECLARE @sql nvarchar(max) = N'USE ' + QUOTENAME(@DatabaseName) + N';
SELECT SYSUTCDATETIME() AS captured_at_utc, name, type_desc,
       size / 128.0 AS allocated_mb,
       CASE WHEN type = 0 THEN (size - FILEPROPERTY(name, ''SpaceUsed'')) / 128.0 END AS free_inside_data_file_mb
FROM sys.database_files;
SELECT df.name, vs.volume_mount_point,
       vs.available_bytes / 1073741824.0 AS volume_free_gb
FROM sys.database_files AS df
CROSS APPLY sys.dm_os_volume_stats(DB_ID(), df.file_id) AS vs;
SELECT total_log_size_in_bytes / 1048576.0 AS total_log_mb,
       used_log_space_in_bytes / 1048576.0 AS used_log_mb,
       used_log_space_in_percent FROM sys.dm_db_log_space_usage;';
EXEC sys.sp_executesql @sql;

SELECT SYSUTCDATETIME() AS captured_at_utc,
       SUM(version_store_reserved_page_count) * 8.0 / 1024 AS instance_tempdb_version_store_mb,
       SUM(unallocated_extent_page_count) * 8.0 / 1024 AS instance_tempdb_unallocated_mb
FROM tempdb.sys.dm_db_file_space_usage;

-- Run locally on each relevant replica for local queue state.
SELECT DB_NAME(database_id) AS database_name, is_local, is_primary_replica,
       synchronization_state_desc, synchronization_health_desc,
       log_send_queue_size AS log_send_queue_kb, redo_queue_size AS redo_queue_kb
FROM sys.dm_hadr_database_replica_states WHERE database_id = @DatabaseId;
