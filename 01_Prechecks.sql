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

SELECT @@VERSION AS full_version, SERVERPROPERTY('Edition') AS edition,
       SERVERPROPERTY('ProductVersion') AS product_version;
SELECT name, compatibility_level, recovery_model_desc,
       is_cdc_enabled, is_published, is_merge_published, is_subscribed,
       group_database_id, log_reuse_wait_desc,
       CASE WHEN is_cdc_enabled = 1
            THEN 'STOP ADR: CDC and ADR are unsupported together on SQL Server 2019.'
            ELSE 'CDC check passed; remaining compatibility review is still required.' END AS adr_cdc_review
FROM sys.databases WHERE database_id = @DatabaseId;

SELECT database_id, mirroring_state_desc, mirroring_role_desc,
       CASE WHEN mirroring_guid IS NOT NULL THEN 'STOP ADR: database mirroring is not supported with ADR.'
            ELSE 'No mirroring configured.' END AS adr_mirroring_review
FROM sys.database_mirroring WHERE database_id = @DatabaseId;

SELECT s.session_id, s.login_name, s.host_name, s.program_name,
       s.status, s.open_transaction_count, r.command, r.wait_type,
       r.blocking_session_id
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
WHERE s.database_id = @DatabaseId OR r.database_id = @DatabaseId
   OR EXISTS (SELECT 1 FROM sys.dm_tran_session_transactions AS st
              JOIN sys.dm_tran_database_transactions AS dt ON dt.transaction_id = st.transaction_id
              WHERE st.session_id = s.session_id AND dt.database_id = @DatabaseId);

SELECT dt.transaction_id, st.session_id, at.transaction_begin_time,
       dt.database_transaction_log_bytes_used, dt.database_transaction_log_bytes_reserved
FROM sys.dm_tran_database_transactions AS dt
LEFT JOIN sys.dm_tran_session_transactions AS st ON st.transaction_id = dt.transaction_id
LEFT JOIN sys.dm_tran_active_transactions AS at ON at.transaction_id = dt.transaction_id
WHERE dt.database_id = @DatabaseId;

DECLARE @sql nvarchar(max) = N'USE ' + QUOTENAME(@DatabaseName) + N';
SELECT name, type_desc, physical_name,
       size / 128.0 AS allocated_mb,
       CASE WHEN type = 0 THEN FILEPROPERTY(name, ''SpaceUsed'') / 128.0 END AS used_data_mb,
       CASE WHEN type = 0 THEN (size - FILEPROPERTY(name, ''SpaceUsed'')) / 128.0 END AS free_inside_data_file_mb,
       max_size, growth, is_percent_growth
FROM sys.database_files;
SELECT df.name, vs.volume_mount_point,
       vs.total_bytes / 1073741824.0 AS volume_total_gb,
       vs.available_bytes / 1073741824.0 AS volume_free_gb
FROM sys.database_files AS df
CROSS APPLY sys.dm_os_volume_stats(DB_ID(), df.file_id) AS vs;
SELECT total_log_size_in_bytes / 1048576.0 AS total_log_mb,
       used_log_space_in_bytes / 1048576.0 AS used_log_mb,
       used_log_space_in_percent
FROM sys.dm_db_log_space_usage;
-- Review these candidates manually; text search is not a dependency audit.
-- Dynamic SQL, encrypted modules and application-issued SQL may be absent.
SELECT OBJECT_SCHEMA_NAME(object_id) AS schema_name,
       OBJECT_NAME(object_id) AS module_name
FROM sys.sql_modules
WHERE definition LIKE ''%NOLOCK%'' OR definition LIKE ''%READPAST%''
   OR definition LIKE ''%UPDLOCK%'' OR definition LIKE ''%READCOMMITTEDLOCK%''
   OR definition LIKE ''%SET TRANSACTION ISOLATION LEVEL%'';';
EXEC sys.sp_executesql @sql;

-- SQL backups recorded on this instance only; these rows do not prove recoverability.
SELECT TOP (15) backup_start_date, backup_finish_date, type,
       is_copy_only, backup_size / 1048576.0 AS backup_mb
FROM msdb.dbo.backupset WHERE database_name = @DatabaseName
ORDER BY backup_finish_date DESC;
-- In an AG also review backup history on backup replicas and validate restore procedures.
