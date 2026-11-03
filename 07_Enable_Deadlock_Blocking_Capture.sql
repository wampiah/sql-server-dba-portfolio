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


/* SERVER-SCOPED Extended Events: captures ALL databases to retain complete graphs,
   including cross-database deadlocks. Reader 09 filters by target database ID.
   XML may contain SQL literals, login names and host names: restrict file access.
   Set the path on the SQL SERVER HOST, not your workstation. The directory must
   exist and SQL Server service account must be able to write there.
   Install on each possible AG primary, with an appropriate local path.
*/
DECLARE @ExecuteChange bit = 0;
DECLARE @EnableInstanceBlockingReports bit = 0; -- explicit instance-wide opt-in if currently OFF
DECLARE @ProposedThresholdSeconds int = 15;
DECLARE @XelFilename nvarchar(260) = N'C:\SQL_XEvents\REPLACE_DATABASE_CAPTURE.xel';
DECLARE @SessionName sysname = N'DBA_RCSI_ADR_' + CONVERT(nvarchar(10),@DatabaseId);
DECLARE @Threshold int, @Advanced int;
SELECT @Threshold=CONVERT(int,value_in_use) FROM sys.configurations WHERE name=N'blocked process threshold (s)';
SELECT @Advanced=CONVERT(int,value_in_use) FROM sys.configurations WHERE name=N'show advanced options';
SELECT @SessionName AS proposed_session, @XelFilename AS proposed_file,
       @Threshold AS current_instance_blocked_threshold_seconds,
       CASE WHEN @Threshold=0 THEN @ProposedThresholdSeconds ELSE @Threshold END AS planned_threshold_seconds,
       @EnableInstanceBlockingReports AS allow_instance_threshold_enable,
       @ExecuteChange AS execute_change;
IF @XelFilename LIKE N'%REPLACE%' OR RIGHT(LOWER(@XelFilename),4)<>N'.xel'
   OR @XelFilename LIKE N'%*%' OR @XelFilename LIKE N'%?%'
    THROW 51110, 'Set a dedicated, reviewed .xel filename on the SQL Server host.', 1;
IF @ProposedThresholdSeconds < 5 OR @ProposedThresholdSeconds > 86400
    THROW 51111, 'Use a reviewed blocking threshold between 5 and 86400 seconds.', 1;
IF @Threshold IS NULL OR @Advanced IS NULL
    THROW 51112, 'Could not determine instance configuration.', 1;
IF @Threshold BETWEEN 1 AND 4
    THROW 51113, 'Existing threshold is 1-4 seconds; review and correct it separately before continuing.', 1;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name=@SessionName)
    THROW 51114, 'Session already exists. Inspect it; this script will not replace an existing capture.', 1;
IF ISNULL(@ExecuteChange,0)<>1 BEGIN PRINT 'PREVIEW ONLY'; RETURN; END;
IF @Threshold=0 AND ISNULL(@EnableInstanceBlockingReports,0)<>1
    THROW 51115, 'Blocking reports are OFF. Explicitly opt in to the instance-wide threshold before execution.', 1;
-- RECONFIGURE can apply unrelated pending options: refuse until they are resolved.
IF @Threshold=0 AND EXISTS (SELECT 1 FROM sys.configurations WHERE value<>value_in_use)
    THROW 51116, 'Pending instance configuration changes exist. Resolve them before this RECONFIGURE.', 1;
DECLARE @sql nvarchar(max)=N'CREATE EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER
ADD EVENT sqlserver.xml_deadlock_report,
ADD EVENT sqlserver.blocked_process_report
ADD TARGET package0.event_file
(SET filename=N'''+REPLACE(@XelFilename,N'''',N'''''')+N''', max_file_size=(50), max_rollover_files=(8))
WITH (MAX_MEMORY=4096 KB, EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,
      MAX_DISPATCH_LATENCY=5 SECONDS, STARTUP_STATE=ON);';
EXEC sys.sp_executesql @sql;
BEGIN TRY
    SET @sql=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER STATE=START;';
    EXEC sys.sp_executesql @sql;
    IF @Threshold=0
    BEGIN
        IF @Advanced=0
        BEGIN
            EXEC sys.sp_configure N'show advanced options',1;
            RECONFIGURE;
        END;
        EXEC sys.sp_configure N'blocked process threshold (s)',@ProposedThresholdSeconds;
        RECONFIGURE;
        IF @Advanced=0
        BEGIN
            EXEC sys.sp_configure N'show advanced options',0;
            RECONFIGURE;
        END;
    END;
END TRY
BEGIN CATCH
    -- Leave the capture for inspection; do not silently drop evidence or reset settings.
    -- Inspect state and restore original show advanced options manually if needed.
    PRINT 'Partial setup possible. Inspect XE session and configuration; do not assume automatic reversal.';
    THROW;
END CATCH;
SELECT name, value, value_in_use FROM sys.configurations
WHERE name IN (N'blocked process threshold (s)',N'show advanced options');
SELECT s.name, s.startup_state,
       CASE WHEN x.name IS NULL THEN 'STOPPED' ELSE 'RUNNING' END AS runtime_state
FROM sys.server_event_sessions AS s
LEFT JOIN sys.dm_xe_sessions AS x ON x.name=s.name WHERE s.name=@SessionName;
-- Deadlocks are captured regardless of duration. Blocking reports are best effort
-- and only cover eligible waits exceeding the threshold; repeated reports can
-- describe the SAME blocking episode. They are not unique incident counts.
