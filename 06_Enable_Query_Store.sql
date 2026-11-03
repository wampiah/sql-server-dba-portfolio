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


IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = @DatabaseId
           AND (state_desc <> N'ONLINE' OR is_read_only = 1))
    THROW 51100, 'Target must be ONLINE and READ_WRITE.', 1;
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = @DatabaseId AND group_database_id IS NOT NULL)
   AND ISNULL(sys.fn_hadr_is_primary_replica(@DatabaseName), 0) <> 1
    THROW 51101, 'Connect to the current AG primary.', 1;

-- Deploy before RCSI/ADR to collect a representative comparison baseline.
-- No application connection drain is normally needed for Query Store enablement.
DECLARE @ExecuteChange bit = 0;
DECLARE @AllowReconfigureExisting bit = 0; -- preserve existing QS unless explicitly reviewed
DECLARE @MaxStorageMB int = 1024; -- per-database starting allocation LIMIT, not preallocation
IF @MaxStorageMB < 128 OR @MaxStorageMB > 32768
    THROW 51102, 'Choose a reviewed storage limit between 128 and 32768 MB for this template.', 1;
DECLARE @CurrentState int, @sql nvarchar(max);
SET @sql = N'USE '+QUOTENAME(@DatabaseName)+N';
SELECT @state = actual_state FROM sys.database_query_store_options;
SELECT SYSUTCDATETIME() AS captured_at_utc, DB_NAME() AS database_name,
       actual_state_desc, desired_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb,
       query_capture_mode_desc, wait_stats_capture_mode_desc,
       interval_length_minutes, stale_query_threshold_days,
       flush_interval_seconds, size_based_cleanup_mode_desc
FROM sys.database_query_store_options;';
EXEC sys.sp_executesql @sql, N'@state int OUTPUT', @state=@CurrentState OUTPUT;
IF @CurrentState IS NULL THROW 51103, 'Could not determine Query Store state.', 1;
IF @CurrentState = 3 THROW 51104, 'Query Store is in ERROR. Investigate instead of overwriting configuration.', 1;
IF @CurrentState <> 0 AND @AllowReconfigureExisting <> 1
BEGIN
    PRINT 'Query Store already exists/enabled. Review returned options; no change made.';
    RETURN;
END;
SET @sql=N'ALTER DATABASE '+QUOTENAME(@DatabaseName)+N' SET QUERY_STORE = ON
(
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = AUTO,
    WAIT_STATS_CAPTURE_MODE = ON,
    MAX_STORAGE_SIZE_MB = '+CONVERT(nvarchar(12),@MaxStorageMB)+N',
    INTERVAL_LENGTH_MINUTES = 15,
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    SIZE_BASED_CLEANUP_MODE = AUTO
);';
SELECT @sql AS proposed_command, @ExecuteChange AS execute_change;
IF ISNULL(@ExecuteChange,0) <> 1 BEGIN PRINT 'PREVIEW ONLY'; RETURN; END;
EXEC sys.sp_executesql @sql;
SET @sql=N'USE '+QUOTENAME(@DatabaseName)+N';
SELECT DB_NAME() AS database_name, actual_state_desc, desired_state_desc,
       readonly_reason, current_storage_size_mb, max_storage_size_mb,
       query_capture_mode_desc, wait_stats_capture_mode_desc
FROM sys.database_query_store_options;
IF NOT EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state=2)
    THROW 51105, ''Query Store did not reach READ_WRITE. Review readonly_reason and capacity.'', 1;';
EXEC sys.sp_executesql @sql;
