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


DECLARE @HoursBack int=24;
IF @HoursBack<1 OR @HoursBack>720 THROW 51120, 'Use 1-720 hours.', 1;
DECLARE @Since datetimeoffset=DATEADD(hour,-@HoursBack,SYSDATETIMEOFFSET());
DECLARE @sql nvarchar(max)=N'USE '+QUOTENAME(@DatabaseName)+N';
SELECT DB_NAME() AS database_name, actual_state_desc, desired_state_desc,
       readonly_reason, current_storage_size_mb, max_storage_size_mb,
       query_capture_mode_desc, wait_stats_capture_mode_desc
FROM sys.database_query_store_options;
-- Runtime rows can be split within the active interval; aggregate by query first.
-- Boundary intervals are included in full; this is an interval-overlap report.
;WITH a AS
(
 SELECT p.query_id, SUM(CONVERT(bigint,r.count_executions)) AS executions,
        SUM(CONVERT(float,r.avg_duration)*r.count_executions) AS total_duration_us,
        SUM(CONVERT(float,r.avg_cpu_time)*r.count_executions) AS total_cpu_us,
        SUM(CONVERT(float,r.avg_logical_io_reads)*r.count_executions) AS logical_reads,
        MAX(r.max_duration) AS max_duration_us
 FROM sys.query_store_runtime_stats AS r
 JOIN sys.query_store_plan AS p ON p.plan_id=r.plan_id
 JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id=r.runtime_stats_interval_id
 WHERE i.end_time>@since
 GROUP BY p.query_id
)
SELECT TOP (25) a.query_id, a.executions,
       a.total_duration_us/1000.0/NULLIF(a.executions,0) AS avg_duration_ms,
       a.max_duration_us/1000.0 AS max_duration_ms,
       a.total_cpu_us/1000.0 AS total_cpu_ms,
       a.logical_reads, t.query_sql_text
FROM a JOIN sys.query_store_query AS q ON q.query_id=a.query_id
JOIN sys.query_store_query_text AS t ON t.query_text_id=q.query_text_id
ORDER BY a.total_duration_us DESC;
-- Lock waits are query-level aggregates, NOT blocker identities or deadlock graphs.
SELECT TOP (25) p.query_id, w.wait_category_desc,
       SUM(w.total_query_wait_time_ms) AS total_query_wait_ms,
       t.query_sql_text
FROM sys.query_store_wait_stats AS w
JOIN sys.query_store_plan AS p ON p.plan_id=w.plan_id
JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id=w.runtime_stats_interval_id
JOIN sys.query_store_query AS q ON q.query_id=p.query_id
JOIN sys.query_store_query_text AS t ON t.query_text_id=q.query_text_id
WHERE i.end_time>@since AND w.wait_category_desc=N''Lock''
GROUP BY p.query_id, w.wait_category_desc, t.query_sql_text
ORDER BY total_query_wait_ms DESC;';
EXEC sys.sp_executesql @sql,N'@since datetimeoffset',@since=@Since;
