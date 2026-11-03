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


-- Use the EXACT dedicated filename prefix chosen in 07; SQL Server appends suffixes.
-- Reading many files can be expensive. Narrow the prefix and time range.
DECLARE @XelPattern nvarchar(260)=N'C:\SQL_XEvents\REPLACE_DATABASE_CAPTURE*.xel';
DECLARE @HoursBack int=24;
IF @XelPattern LIKE N'%REPLACE%' THROW 51130, 'Set the capture file pattern on the SQL Server host.', 1;
IF @HoursBack<1 OR @HoursBack>720 THROW 51131, 'Use 1-720 hours.', 1;
DECLARE @SinceUTC datetime2=DATEADD(hour,-@HoursBack,SYSUTCDATETIME());
;WITH events AS
(
 SELECT file_name, file_offset, TRY_CAST(event_data AS xml) AS event_xml
 FROM sys.fn_xe_file_target_read_file(@XelPattern,NULL,NULL,NULL)
 WHERE object_name IN (N'xml_deadlock_report',N'blocked_process_report')
), filtered AS
(
 SELECT file_name,file_offset,event_xml,
        event_xml.value('(event/@name)[1]','sysname') AS event_name,
        event_xml.value('(event/@timestamp)[1]','datetime2') AS event_time_utc
 FROM events
 WHERE event_xml.exist('/event/data/value/deadlock/process-list/process[@currentdb=sql:variable("@DatabaseId")]')=1
    OR event_xml.exist('/event/data/value/deadlock/resource-list/*[@dbid=sql:variable("@DatabaseId")]')=1
    OR event_xml.exist('/event/data/value/blocked-process-report/blocked-process/process[@currentdb=sql:variable("@DatabaseId")]')=1
    OR event_xml.exist('/event/data/value/blocked-process-report/blocking-process/process[@currentdb=sql:variable("@DatabaseId")]')=1
    OR event_xml.exist('/event/data[@name="database_id"]/value[.=sql:variable("@DatabaseId")]')=1
)
SELECT event_time_utc,event_name,
       CASE WHEN event_name=N'blocked_process_report' THEN event_xml.value('(event/data/value/blocked-process-report/blocked-process/process/@spid)[1]','int') END AS blocked_spid,
       CASE WHEN event_name=N'blocked_process_report' THEN event_xml.value('(event/data/value/blocked-process-report/blocking-process/process/@spid)[1]','int') END AS blocker_spid,
       CASE WHEN event_name=N'blocked_process_report' THEN event_xml.value('(event/data/value/blocked-process-report/blocked-process/process/@waittime)[1]','bigint') END AS reported_wait_ms,
       event_xml.query('/event/data/value/deadlock') AS deadlock_xml,
       event_xml.query('/event/data/value/blocked-process-report') AS blocking_xml,
       file_name,file_offset,event_xml
FROM filtered WHERE event_time_utc>=@SinceUTC
ORDER BY event_time_utc DESC;
-- Empty results do not prove no historical incidents: files roll over and
-- reports only exist after capture starts. The filter uses the CURRENT database ID;
-- restore/recreate/move/rename history may need separate correlation.
-- Keep file_name+file_offset when deduplicating repeated file reads.
