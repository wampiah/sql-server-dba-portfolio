/*
AG HEALTH CHECK - run unchanged on primary and every secondary, in master.
Target: conventional SQL Server Always On AGs, SQL Server 2012-2022.
Not an Azure SQL Database / Managed Instance service HA check. Distributed
AGs and external/read-scale clusters need topology-specific interpretation.
Read-only against permanent objects; writes only session temp tables.
Permissions: VIEW SERVER STATE (2012-2019), VIEW SERVER PERFORMANCE STATE
(2022); metadata visibility is also required. Sysadmin is sufficient.

Results: 1 Replica health; 2 Database health/queues/readiness; 3 Local log reuse.
Primary reports local and remote replicas; secondary reports local replica only.
Remote values are last reported values, potentially stale. NULL means unknown
or not applicable, never zero. Snapshots are sequential, not atomic.
Use @IssuesOnly=1 for concise output. Empty output then means no flagged rows
in the observed scope, NOT an end-to-end service health guarantee.

Thresholds below are starting examples, not Microsoft recommendations.
Trend queues over repeated runs against your workload and recovery objectives.
Queue/rate estimates ignore new log generation and use historical active rates;
they are NOT predicted failover durations. Nonzero redo does not alone mean
data loss: synchronous commit waits for hardening, not completion of redo.
Last*Time values are returned unchanged in SQL Server's reported time basis.
CheckTimeUTC is UTC. No timestamp-age alarm: an idle database can be healthy.
Readiness is per database, not permission/approval to fail over the AG.
Verify every database, replica health, quorum and topology before failover.
No failover, resume, restart or configuration commands are executed.
*/
USE master;
SET NOCOUNT ON;

DECLARE @IssuesOnly bit = 0;
DECLARE @AGName sysname = NULL;       -- NULL = all local AGs
DECLARE @DatabaseName sysname = NULL; -- NULL = all AG databases
DECLARE @SendQueueWarnMB decimal(19,2) = 100;
DECLARE @RedoQueueWarnMB decimal(19,2) = 100;
DECLARE @CheckTimeUTC datetime2(0) = SYSUTCDATETIME();
DECLARE @ServerName nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName'));

IF ISNULL(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), 0) <> 1
BEGIN
    SELECT @CheckTimeUTC AS CheckTimeUTC, @ServerName AS ReportingServer,
           'INFO' AS Status, 'Always On is not enabled on this instance.' AS Finding;
    RETURN;
END;

IF OBJECT_ID('tempdb..#AGReplicas') IS NOT NULL DROP TABLE #AGReplicas;
IF OBJECT_ID('tempdb..#AGDatabases') IS NOT NULL DROP TABLE #AGDatabases;
IF OBJECT_ID('tempdb..#AGClusterDB') IS NOT NULL DROP TABLE #AGClusterDB;
IF OBJECT_ID('tempdb..#AGResults') IS NOT NULL DROP TABLE #AGResults;

BEGIN TRY
    SELECT ag.group_id, ag.name AS AGName, ar.replica_id,
           ar.replica_server_name AS ReplicaServer,
           ar.availability_mode, ar.availability_mode_desc AS CommitMode,
           ar.failover_mode_desc AS FailoverMode,
           lr.role AS LocalRole, lr.role_desc AS ReportingRole,
           rs.is_local, rs.role, rs.role_desc AS ReplicaRole,
           rs.operational_state_desc AS OperationalState,
           rs.connected_state, rs.connected_state_desc AS ConnectionState,
           rs.recovery_health_desc AS RecoveryHealth,
           rs.synchronization_health, rs.synchronization_health_desc AS SyncHealth,
           rs.last_connect_error_number, rs.last_connect_error_description,
           rs.last_connect_error_timestamp
    INTO #AGReplicas
    FROM sys.availability_groups AS ag
    JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
    JOIN sys.dm_hadr_availability_replica_states AS lr
      ON lr.group_id = ag.group_id AND lr.is_local = 1
    LEFT JOIN sys.dm_hadr_availability_replica_states AS rs
      ON rs.group_id = ar.group_id AND rs.replica_id = ar.replica_id
    WHERE (@AGName IS NULL OR ag.name = @AGName)
      AND (lr.role = 1 OR ar.replica_id = lr.replica_id);

    SELECT * INTO #AGDatabases FROM sys.dm_hadr_database_replica_states;
END TRY
BEGIN CATCH
    SELECT @CheckTimeUTC AS CheckTimeUTC, @ServerName AS ReportingServer,
           'ERROR' AS Status, ERROR_MESSAGE() AS Finding;
    RETURN;
END CATCH;

IF NOT EXISTS (SELECT 1 FROM #AGReplicas)
BEGIN
    SELECT @CheckTimeUTC AS CheckTimeUTC, @ServerName AS ReportingServer,
           'UNKNOWN' AS Status,
           'No visible local AG matched. Check filter, permissions and local AG/cluster state.' AS Finding;
    RETURN;
END;

-- A cluster query failure must not suppress the other diagnostics.
CREATE TABLE #AGClusterDB
(
    replica_id uniqueidentifier,
    group_database_id uniqueidentifier,
    is_database_joined bit NULL,
    is_failover_ready bit NULL
);
BEGIN TRY
    INSERT #AGClusterDB
    SELECT replica_id, group_database_id, is_database_joined, is_failover_ready
    FROM sys.dm_hadr_database_replica_cluster_states;
END TRY
BEGIN CATCH
    SELECT @CheckTimeUTC AS CheckTimeUTC, @ServerName AS ReportingServer,
           'UNKNOWN' AS Status,
           'Cluster database readiness unavailable: ' + ERROR_MESSAGE() AS Finding;
END CATCH;

-- 1. Replica health. Last connection error is historical unless corroborated
-- by the current connection state. Remote operational/recovery NULLs are normal.
;WITH R AS
(
    SELECT *,
      CASE
        WHEN role = 0 OR (is_local = 1 AND OperationalState IN
             ('FAILED','FAILED_NO_QUORUM','OFFLINE')) THEN 'ERROR'
        WHEN role = 2 AND connected_state = 0 THEN 'ERROR'
        WHEN synchronization_health = 0 THEN 'ERROR'
        WHEN role IS NULL OR synchronization_health IS NULL THEN 'UNKNOWN'
        WHEN synchronization_health = 1 THEN 'WARN'
        WHEN is_local = 1 AND ISNULL(OperationalState,'UNKNOWN') <> 'ONLINE' THEN 'WARN'
        ELSE 'OK'
      END AS Status
    FROM #AGReplicas
)
SELECT @CheckTimeUTC AS CheckTimeUTC, @ServerName AS ReportingServer,
       AGName, ReportingRole, ReplicaServer, is_local AS IsLocal, Status,
       ReplicaRole, CommitMode, FailoverMode, ConnectionState,
       OperationalState, RecoveryHealth, SyncHealth,
       last_connect_error_number AS LastConnectErrorNumber,
       last_connect_error_description AS LastConnectErrorDescription,
       last_connect_error_timestamp AS LastConnectErrorTimeReported
FROM R
WHERE @IssuesOnly = 0 OR Status <> 'OK'
ORDER BY AGName, ReplicaServer;

-- 2. Expected database/replica grid catches missing DMV rows or unjoined DBs.
-- Match by group_database_id: database_id is instance-specific.
SELECT r.AGName, r.ReportingRole, r.ReplicaServer, r.ReplicaRole,
       r.CommitMode, r.FailoverMode, adc.database_name AS DatabaseName,
       CASE
         WHEN c.is_database_joined = 0 THEN 'ERROR'
         WHEN r.role = 0 OR (r.role = 2 AND r.connected_state = 0) THEN 'ERROR'
         WHEN d.is_suspended = 1 OR d.synchronization_state IN (0,3,4) THEN 'ERROR'
         WHEN d.database_state IS NOT NULL AND d.database_state <> 0 THEN 'ERROR'
         WHEN d.replica_id IS NULL OR r.role IS NULL
           OR d.synchronization_state IS NULL THEN 'UNKNOWN'
         WHEN r.availability_mode = 1 AND d.synchronization_state <> 2 THEN 'WARN'
         WHEN d.synchronization_health IS NULL THEN 'UNKNOWN'
         WHEN d.synchronization_health <> 2 THEN 'WARN'
         WHEN d.log_send_queue_size / 1024.0 >= @SendQueueWarnMB
           OR d.redo_queue_size / 1024.0 >= @RedoQueueWarnMB THEN 'WARN'
         WHEN r.role = 2 AND r.availability_mode = 1 AND c.is_failover_ready = 0 THEN 'WARN'
         ELSE 'OK'
       END AS Status,
       CASE
         WHEN c.is_database_joined = 0 THEN 'Database not joined on this replica'
         WHEN d.replica_id IS NULL THEN 'No database DMV row: inspect connection, join/seeding and permissions'
         WHEN d.is_suspended = 1 THEN 'Data movement suspended: inspect SuspendReason'
         WHEN d.synchronization_state IN (0,3,4) THEN 'Data movement not in normal operating state'
         WHEN d.database_state IS NOT NULL AND d.database_state <> 0 THEN 'Database not ONLINE'
         WHEN r.role = 2 AND r.connected_state = 0 THEN 'Replica disconnected; reported database values may be stale'
         WHEN r.availability_mode = 1 AND d.synchronization_state <> 2 THEN 'Synchronous database not SYNCHRONIZED'
         WHEN d.log_send_queue_size / 1024.0 >= @SendQueueWarnMB
           OR d.redo_queue_size / 1024.0 >= @RedoQueueWarnMB THEN 'Queue exceeds configured example threshold; inspect trend'
         WHEN r.role = 2 AND r.availability_mode = 1 AND c.is_failover_ready = 0 THEN 'Cluster has not marked database failover ready'
         ELSE 'Review state and readiness columns; NULL = unknown/not applicable'
       END AS Finding,
       d.is_local AS IsLocal, d.database_state_desc AS DatabaseState,
       d.synchronization_state_desc AS SyncState,
       d.synchronization_health_desc AS SyncHealth,
       d.is_suspended AS IsSuspended, d.suspend_reason_desc AS SuspendReason,
       c.is_database_joined AS ClusterIsDatabaseJoined,
       c.is_failover_ready AS ClusterIsFailoverReady,
       CASE
         WHEN r.role = 1 THEN 'PRIMARY - not a failover target'
         WHEN r.role IS NULL OR r.role <> 2 THEN 'UNKNOWN / RESOLVING'
         WHEN r.availability_mode = 0 THEN 'ASYNC - no guaranteed lossless planned failover'
         WHEN r.availability_mode <> 1 THEN 'REVIEW COMMIT MODE'
         WHEN c.is_failover_ready IS NULL THEN 'UNKNOWN - cluster readiness unavailable'
         WHEN c.is_failover_ready = 1 AND c.is_database_joined = 1
           AND d.synchronization_state = 2 AND d.is_suspended = 0
           AND d.database_state = 0 AND r.connected_state = 1
           THEN 'DATABASE READY - verify all databases and AG prerequisites'
         ELSE 'DATABASE NOT READY / INCOMPLETE EVIDENCE'
       END AS DatabaseFailoverAssessment,
       CAST(d.log_send_queue_size / 1024.0 AS decimal(19,2)) AS SendQueueMB,
       d.log_send_rate AS SendRateKBsec,
       CAST(d.redo_queue_size / 1024.0 AS decimal(19,2)) AS RedoQueueMB,
       d.redo_rate AS RedoRateKBsec,
       CAST(d.log_send_queue_size * 1.0 / NULLIF(d.log_send_rate,0)
            AS decimal(19,1)) AS SendDrainSecondsEstimate,
       CAST(d.redo_queue_size * 1.0 / NULLIF(d.redo_rate,0)
            AS decimal(19,1)) AS RedoDrainSecondsEstimate,
       d.last_sent_time AS LastSentTimeReported,
       d.last_received_time AS LastReceivedTimeReported,
       d.last_hardened_time AS LastHardenedTimeReported,
       d.last_redone_time AS LastRedoneTimeReported,
       d.last_commit_time AS LastCommitTimeReported,
       d.last_received_lsn, d.last_hardened_lsn, d.last_redone_lsn
INTO #AGResults
FROM #AGReplicas AS r
JOIN sys.availability_databases_cluster AS adc ON adc.group_id = r.group_id
LEFT JOIN #AGDatabases AS d
  ON d.replica_id = r.replica_id AND d.group_database_id = adc.group_database_id
LEFT JOIN #AGClusterDB AS c
  ON c.replica_id = r.replica_id AND c.group_database_id = adc.group_database_id
WHERE @DatabaseName IS NULL OR adc.database_name = @DatabaseName;

SELECT @CheckTimeUTC AS CheckTimeUTC, @ServerName AS ReportingServer, *
FROM #AGResults
WHERE @IssuesOnly = 0 OR Status <> 'OK'
ORDER BY AGName, DatabaseName, ReplicaServer;

-- 3. Local log reuse only: AVAILABILITY_REPLICA is a clue to correlate with
-- queues/trends and log free space, not proof that the log is filling up.
SELECT @CheckTimeUTC AS CheckTimeUTC, @ServerName AS ReportingServer,
       r.AGName, r.ReportingRole, db.name AS DatabaseName,
       CASE WHEN db.log_reuse_wait_desc = 'AVAILABILITY_REPLICA'
            THEN 'REVIEW' ELSE 'INFO' END AS Status,
       db.state_desc AS LocalDatabaseState, db.recovery_model_desc AS RecoveryModel,
       db.log_reuse_wait_desc AS LogReuseWait
FROM sys.databases AS db
JOIN #AGDatabases AS d ON d.database_id = db.database_id AND d.is_local = 1
JOIN #AGReplicas AS r ON r.replica_id = d.replica_id AND r.group_id = d.group_id
WHERE (@DatabaseName IS NULL OR db.name = @DatabaseName)
  AND (@IssuesOnly = 0 OR db.log_reuse_wait_desc = 'AVAILABILITY_REPLICA')
ORDER BY r.AGName, db.name;

IF @DatabaseName IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #AGResults)
    SELECT @CheckTimeUTC AS CheckTimeUTC, @ServerName AS ReportingServer,
           'INFO' AS Status, 'No visible AG database matched @DatabaseName.' AS Finding;

DROP TABLE #AGResults;
DROP TABLE #AGClusterDB;
DROP TABLE #AGDatabases;
DROP TABLE #AGReplicas;
