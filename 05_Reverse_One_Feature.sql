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

DECLARE @Feature varchar(4) = 'NONE'; -- choose RCSI or ADR; one per execution
DECLARE @ExecuteChange bit = 0;
DECLARE @BaselineWasOff bit = 0; -- set to 1 ONLY if saved prechecks prove it was OFF

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
           AND (state_desc <> N'ONLINE' OR is_read_only = 1 OR user_access_desc <> N'MULTI_USER'))
    THROW 51007, 'Target must be ONLINE, READ_WRITE and MULTI_USER.', 1;
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = @DatabaseId AND group_database_id IS NOT NULL)
   AND ISNULL(sys.fn_hadr_is_primary_replica(@DatabaseName), 0) <> 1
    THROW 51008, 'For an availability-group database, connect to its current primary replica.', 1;

SELECT CONVERT(sysname, SERVERPROPERTY('ServerName')) AS server_name,
       SYSUTCDATETIME() AS captured_at_utc, name,
       state_desc, user_access_desc, is_read_only,
       is_read_committed_snapshot_on,
       snapshot_isolation_state_desc,
       is_accelerated_database_recovery_on
FROM sys.databases WHERE database_id = @DatabaseId;

IF @Feature IS NULL OR @Feature NOT IN ('RCSI', 'ADR')
    THROW 51030, 'Select exactly one feature: RCSI or ADR.', 1;
IF @BaselineWasOff <> 1
    THROW 51031, 'Confirm from the saved baseline that this feature was OFF before this deployment.', 1;
DECLARE @sql nvarchar(max) = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET ' +
    CASE @Feature
        WHEN 'RCSI' THEN N'READ_COMMITTED_SNAPSHOT OFF WITH NO_WAIT;'
        WHEN 'ADR'  THEN N'ACCELERATED_DATABASE_RECOVERY = OFF WITH NO_WAIT;'
    END;
SELECT @sql AS proposed_command, @ExecuteChange AS execute_change;
IF @ExecuteChange = 0
BEGIN
    PRINT 'PREVIEW ONLY: no configuration change made.';
    RETURN;
END;

-- Drain application access before changing RCSI or ADR.
-- Includes sessions using another context but holding a transaction in this database.
IF EXISTS (SELECT 1 FROM sys.dm_exec_sessions
           WHERE session_id <> @@SPID AND database_id = @DatabaseId)
 OR EXISTS (SELECT 1 FROM sys.dm_exec_requests
            WHERE session_id <> @@SPID AND database_id = @DatabaseId)
 OR EXISTS (SELECT 1 FROM sys.dm_tran_database_transactions
            WHERE database_id = @DatabaseId)
    THROW 51010, 'Target is not drained: stop application pools, jobs and monitoring connections; allow transactions to finish, then retry.', 1;

DECLARE @PreviousLockTimeout int = @@LOCK_TIMEOUT;
BEGIN TRY
    SET LOCK_TIMEOUT 15000;
    EXEC sys.sp_executesql @sql;
    SET LOCK_TIMEOUT @PreviousLockTimeout;
END TRY
BEGIN CATCH
    SET LOCK_TIMEOUT @PreviousLockTimeout;
    THROW;
END CATCH;

SELECT CONVERT(sysname, SERVERPROPERTY('ServerName')) AS server_name,
       SYSUTCDATETIME() AS captured_at_utc, name,
       state_desc, user_access_desc, is_read_only,
       is_read_committed_snapshot_on,
       snapshot_isolation_state_desc,
       is_accelerated_database_recovery_on
FROM sys.databases WHERE database_id = @DatabaseId;

IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = @DatabaseId
           AND ((@Feature = 'RCSI' AND is_read_committed_snapshot_on <> 0)
             OR (@Feature = 'ADR' AND is_accelerated_database_recovery_on <> 0)))
    THROW 51034, 'Feature did not reach OFF. Investigate before reconnecting applications.', 1;
PRINT 'Selected feature verified OFF. Run application smoke tests and monitoring.';
PRINT 'ADR OFF does not immediately reclaim PVS space. No shrink or forced cleanup was performed.';
-- Turning ADR off while RCSI/SI remain on moves new isolation versions to tempdb.
-- Ensure tempdb has capacity before this reversal. Never use disable/shrink as a quick PVS fix.
