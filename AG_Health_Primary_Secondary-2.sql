/* AG health, SQL Server 2012-2025 (11.x-17.x). Execute on primary and secondaries.
   SSMS Registered Servers: exactly one seven-column result set per instance.
   Read-only permanent objects; only #temp output. By default report issues
   and one PASS row if none were found on this instance. NULL = unknown,
   never zero. Remote replica state on a primary is last reported, possibly
   stale; a secondary mainly reports its own local state. Synchronous and
   asynchronous commit have different expected sync states. A redo queue
   alone does not establish data loss. Review ALL databases before failover.
   SQL Server 2012-2019: VIEW SERVER STATE; 2022/2025: VIEW SERVER PERFORMANCE STATE.
*/
USE master;
SET NOCOUNT ON;
DECLARE @IssuesOnly bit = 1; -- 0 = include healthy replica/database rows
DECLARE @AGName sysname = NULL;
DECLARE @DatabaseName sysname = NULL;
DECLARE @SendQueueWarnMB decimal(19,2) = 100; -- tune to workload/RPO
DECLARE @RedoQueueWarnMB decimal(19,2) = 100; -- example, not failover criterion
DECLARE @UTC datetime2(7) = SYSUTCDATETIME();
DECLARE @Server nvarchar(128)=CONVERT(nvarchar(128),SERVERPROPERTY('ServerName'));

IF OBJECT_ID('tempdb..#AGHealthOutput') IS NOT NULL DROP TABLE #AGHealthOutput;
CREATE TABLE #AGHealthOutput
(CheckTimeUTC datetime2(7) NOT NULL, ServerName nvarchar(128) NULL,
 Resource nvarchar(512) NULL, CheckName nvarchar(256) NOT NULL,
 Status nvarchar(16) NOT NULL, Finding nvarchar(2048) NULL, Evidence nvarchar(4000) NULL);

BEGIN TRY
  IF ISNULL(CONVERT(int,SERVERPROPERTY('IsHadrEnabled')),0)<>1
    INSERT #AGHealthOutput VALUES
      (@UTC,@Server,N'Instance',N'Availability groups',N'INFO',N'Always On not enabled',NULL);
  ELSE
  BEGIN
    IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;
    SELECT ag.group_id,ag.name AS AGName,ar.replica_id,
      ar.replica_server_name AS ReplicaServer,ar.availability_mode AS CommitModeCode,
      ar.availability_mode_desc AS CommitMode,ar.failover_mode_desc AS FailoverMode,
      local_rs.role_desc AS ReportingRole,
      rs.role,rs.role_desc AS ReplicaRole,rs.is_local,rs.connected_state,
      rs.connected_state_desc AS ConnectionState,rs.operational_state_desc AS OperationalState,
      rs.synchronization_health,rs.synchronization_health_desc AS SyncHealth,
      rs.last_connect_error_number,rs.last_connect_error_description,
      rs.last_connect_error_timestamp
    INTO #R FROM sys.availability_groups ag
    JOIN sys.availability_replicas ar ON ar.group_id=ag.group_id
    JOIN sys.dm_hadr_availability_replica_states local_rs
      ON local_rs.group_id=ag.group_id AND local_rs.is_local=1
    LEFT JOIN sys.dm_hadr_availability_replica_states rs
      ON rs.group_id=ag.group_id AND rs.replica_id=ar.replica_id
    WHERE (@AGName IS NULL OR ag.name=@AGName)
      AND (local_rs.role=1 OR ar.replica_id=local_rs.replica_id);

    IF NOT EXISTS(SELECT 1 FROM #R)
      INSERT #AGHealthOutput VALUES(@UTC,@Server,N'Instance',N'Availability groups',
        N'UNKNOWN',N'No local AG visible for selected filter; check membership and permissions',NULL);
    ELSE
    BEGIN
      ;WITH ReplicaCheck AS
      (
        SELECT *,CASE
          WHEN role=0 OR (is_local=1 AND OperationalState IN
            (N'FAILED',N'FAILED_NO_QUORUM',N'OFFLINE')) THEN N'ERROR'
          WHEN role=2 AND connected_state=0 THEN N'ERROR'
          WHEN synchronization_health=0 THEN N'ERROR'
          WHEN role IS NULL OR synchronization_health IS NULL THEN N'UNKNOWN'
          WHEN synchronization_health=1 THEN N'WARN'
          WHEN is_local=1 AND ISNULL(OperationalState,N'UNKNOWN')<>N'ONLINE' THEN N'WARN'
          ELSE N'OK' END AS HealthStatus
        FROM #R
      )
      INSERT #AGHealthOutput(CheckTimeUTC,ServerName,Resource,CheckName,Status,Finding,Evidence)
      SELECT @UTC,@Server,AGName,N'Replica: '+ReplicaServer,HealthStatus,
        CONCAT(N'Role=',COALESCE(ReplicaRole,N'UNKNOWN'),N'; Sync=',
          COALESCE(SyncHealth,N'UNKNOWN'),N'; Connection=',COALESCE(ConnectionState,N'UNKNOWN')),
        CONCAT(N'CheckedFrom=',COALESCE(ReportingRole,N'UNKNOWN'),
          N'; Commit=',CommitMode,N'; Failover=',FailoverMode,
          N'; Operational=',COALESCE(OperationalState,N'NULL'),
          N'; LastConnectError=',COALESCE(CONVERT(nvarchar(12),last_connect_error_number),N'NULL'),
          N'; LastErrorAt=',COALESCE(CONVERT(nvarchar(33),last_connect_error_timestamp,126),N'NULL'))
      FROM ReplicaCheck WHERE @IssuesOnly=0 OR HealthStatus<>N'OK';

      ;WITH DbCheck AS
      (
        SELECT r.*,adc.database_name AS DatabaseName,
          d.is_local AS DatabaseIsLocal,d.database_state,d.database_state_desc,
          d.synchronization_state,d.synchronization_state_desc,
          d.synchronization_health AS DbSyncHealth,d.is_suspended,d.suspend_reason_desc,
          d.log_send_queue_size,d.log_send_rate,d.redo_queue_size,d.redo_rate,
          d.last_received_time,d.last_hardened_time,d.last_redone_time,
          c.is_database_joined,c.is_failover_ready,
          CASE WHEN c.is_database_joined=0 THEN N'ERROR'
            WHEN r.role=0 OR (r.role=2 AND r.connected_state=0) THEN N'ERROR'
            WHEN d.is_suspended=1 OR d.synchronization_state IN (0,3,4) THEN N'ERROR'
            WHEN d.database_state IS NOT NULL AND d.database_state<>0 THEN N'ERROR'
            WHEN d.replica_id IS NULL OR r.role IS NULL OR d.synchronization_state IS NULL THEN N'UNKNOWN'
            WHEN r.CommitModeCode=1 AND d.synchronization_state<>2 THEN N'WARN'
            WHEN d.synchronization_health IS NULL THEN N'UNKNOWN'
            WHEN d.synchronization_health<>2 THEN N'WARN'
            WHEN r.role=2 AND r.CommitModeCode=1 AND c.is_failover_ready IS NULL THEN N'UNKNOWN'
            WHEN d.log_send_queue_size/1024.0>=@SendQueueWarnMB
              OR d.redo_queue_size/1024.0>=@RedoQueueWarnMB THEN N'WARN'
            WHEN r.role=2 AND r.CommitModeCode=1 AND c.is_failover_ready=0 THEN N'WARN'
            ELSE N'OK' END AS HealthStatus
        FROM #R r JOIN sys.availability_databases_cluster adc ON adc.group_id=r.group_id
        LEFT JOIN sys.dm_hadr_database_replica_states d
          ON d.replica_id=r.replica_id AND d.group_database_id=adc.group_database_id
        LEFT JOIN sys.dm_hadr_database_replica_cluster_states c
          ON c.replica_id=r.replica_id AND c.group_database_id=adc.group_database_id
        WHERE @DatabaseName IS NULL OR adc.database_name=@DatabaseName
      )
      INSERT #AGHealthOutput(CheckTimeUTC,ServerName,Resource,CheckName,Status,Finding,Evidence)
      SELECT @UTC,@Server,AGName+N' / '+DatabaseName,N'Database: '+ReplicaServer,
        HealthStatus,
        CONCAT(N'Role=',COALESCE(ReplicaRole,N'UNKNOWN'),
          N'; Sync=',COALESCE(synchronization_state_desc,N'UNKNOWN'),
          N'; Suspended=',COALESCE(CONVERT(nvarchar(1),is_suspended),N'NULL'),
          N'; FailoverReady=',COALESCE(CONVERT(nvarchar(1),is_failover_ready),N'NULL')),
        CONCAT(N'Commit=',CommitMode,
          N'; DBState=',COALESCE(database_state_desc,N'NULL'),
          N'; Joined=',COALESCE(CONVERT(nvarchar(1),is_database_joined),N'NULL'),
          N'; SuspendReason=',COALESCE(suspend_reason_desc,N'NULL'),
          N'; SendQueueKB=',COALESCE(CONVERT(nvarchar(30),log_send_queue_size),N'NULL'),
          N'; SendRateKBps=',COALESCE(CONVERT(nvarchar(30),log_send_rate),N'NULL'),
          N'; RedoQueueKB=',COALESCE(CONVERT(nvarchar(30),redo_queue_size),N'NULL'),
          N'; RedoRateKBps=',COALESCE(CONVERT(nvarchar(30),redo_rate),N'NULL'),
          N'; LastHardened=',COALESCE(CONVERT(nvarchar(33),last_hardened_time,126),N'NULL'))
      FROM DbCheck WHERE @IssuesOnly=0 OR HealthStatus<>N'OK';

      IF @DatabaseName IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM sys.availability_databases_cluster adc JOIN #R r ON r.group_id=adc.group_id
         WHERE adc.database_name=@DatabaseName)
        INSERT #AGHealthOutput VALUES(@UTC,@Server,@DatabaseName,N'AG database',
          N'UNKNOWN',N'Filtered database not visible in a local AG',NULL);

      IF @DatabaseName IS NULL AND NOT EXISTS
        (SELECT 1 FROM sys.availability_databases_cluster adc JOIN #R r ON r.group_id=adc.group_id)
        INSERT #AGHealthOutput VALUES(@UTC,@Server,N'Availability groups',N'AG database visibility',
          N'UNKNOWN',N'No AG database metadata visible; replica-only checks do not establish database health',NULL);

      IF NOT EXISTS(SELECT 1 FROM #AGHealthOutput)
        INSERT #AGHealthOutput VALUES(@UTC,@Server,N'Availability groups',N'AG health',
          N'PASS',N'No flagged replica/database rows in the observed scope',
          N'Snapshot only; validate remote states on their own replicas');
    END;
  END;
END TRY
BEGIN CATCH
  INSERT #AGHealthOutput(CheckTimeUTC,ServerName,Resource,CheckName,Status,Finding,Evidence)
  VALUES(@UTC,@Server,N'Availability groups',N'AG health',N'UNKNOWN',
    LEFT(ERROR_MESSAGE(),2048),CONCAT(N'Error=',ERROR_NUMBER()));
END CATCH;

SELECT CheckTimeUTC,ServerName,Resource,CheckName,Status,Finding,Evidence
FROM #AGHealthOutput ORDER BY Resource,CheckName,Finding;
