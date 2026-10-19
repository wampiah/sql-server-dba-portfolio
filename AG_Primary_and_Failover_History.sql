/* AG PRIMARY / FAILOVER HISTORY - SQL Server 2016-2022, conventional AGs.
Run on EACH replica in master. Read-only except session-scoped temp tables.
Permissions: VIEW SERVER STATE (2016-2019), VIEW SERVER PERFORMANCE STATE (2022),
plus metadata visibility. No XE session is started/stopped or modified.

Set @LastChecked with its UTC/BST/GMT offset for the exact prior check.
NULL defaults to midnight UK time on the previous weekday:
Monday -> Friday; Tuesday-Friday -> preceding day; weekend -> Friday.
This deliberate overlap covers the previous weekday and the whole weekend.
It does not account for bank holidays or missed checks: supply @LastChecked
after a longer gap. This script neither schedules checks nor stores a cursor.
Save WindowEndUTC and use it as @LastChecked next time (with +00:00).
No previous-check timestamp is stored automatically.

Uses all retained alwayson_health event files, including before the window,
to find the last observed PRIMARY_NORMAL entry and preceding stable role.
PRIMARY_NORMAL is evidence of role activation, not end-to-end application
recovery, zero data loss, or proof of manual versus automatic failover.
A prior SECONDARY_NORMAL then PRIMARY_NORMAL supports a local promotion.
Startup, AG creation and rejoin can also produce role events.
Correlate both replicas, SQL logs, cluster logs and application checks.
No events found means NO RETAINED EVIDENCE, never 'no failover occurred'.
The latest PRIMARY_NORMAL entry is not guaranteed to be the original start
of continuous tenure: restarts/recovery may re-enter primary on the same host.
Retention timestamps do not establish uninterrupted capture; events can be
dropped, buffered, filtered or lost while the session is stopped.
The UK column automatically handles BST/GMT; UTC columns are authoritative.
History is local to this SQL instance, not a complete cross-node timeline.
*/
USE master;
SET NOCOUNT ON;

DECLARE @LastChecked datetimeoffset(7) = NULL;
-- Example: '2026-10-19T09:00:00+01:00' = 09:00 UK during BST.
DECLARE @AGName sysname = NULL;
DECLARE @XelPattern nvarchar(4000) = NULL; -- Override, e.g. N'D:\SQLLog\AlwaysOn_health*.xel'
DECLARE @WindowEndUTC datetime2(7) = SYSUTCDATETIME();
DECLARE @TodayUK date = CONVERT(date,
    @WindowEndUTC AT TIME ZONE 'UTC' AT TIME ZONE 'GMT Standard Time');
-- 1900-01-01 was Monday. Independent of SET DATEFIRST / language.
DECLARE @WeekdayMondayZero int = DATEDIFF(day,CONVERT(date,'19000101',112),@TodayUK) % 7;
DECLARE @PreviousWeekday date = DATEADD(day,
    CASE @WeekdayMondayZero WHEN 0 THEN -3 WHEN 6 THEN -2 ELSE -1 END,@TodayUK);
DECLARE @DefaultStartUTC datetime2(7) = CONVERT(datetime2(7),
    CONVERT(datetime2(7),@PreviousWeekday) AT TIME ZONE 'GMT Standard Time' AT TIME ZONE 'UTC');
DECLARE @WindowStartUTC datetime2(7) = COALESCE(
    CONVERT(datetime2(7), SWITCHOFFSET(@LastChecked, '+00:00')),
    @DefaultStartUTC);
DECLARE @ServerName nvarchar(128) = CONVERT(nvarchar(128),SERVERPROPERTY('ServerName'));
DECLARE @Configured nvarchar(4000), @Active nvarchar(4000), @Target xml;
DECLARE @SessionRunning bit = 0, @StateEventConfigured bit = 0;

IF @WindowStartUTC > @WindowEndUTC
BEGIN
    RAISERROR('Last-checked timestamp is in the future.',16,1);
    RETURN;
END;

BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'alwayson_health')
        SET @SessionRunning = 1;
    IF EXISTS (SELECT 1 FROM sys.server_event_sessions s
               JOIN sys.server_event_session_events e ON e.event_session_id=s.event_session_id
               WHERE s.name=N'alwayson_health' AND e.name=N'availability_replica_state_change')
        SET @StateEventConfigured = 1;

    SELECT @Configured=CONVERT(nvarchar(4000),f.value)
    FROM sys.server_event_sessions s
    JOIN sys.server_event_session_targets t ON t.event_session_id=s.event_session_id
    JOIN sys.server_event_session_fields f
      ON f.event_session_id=t.event_session_id AND f.object_id=t.target_id
    WHERE s.name=N'alwayson_health' AND t.name=N'event_file' AND f.name=N'filename';

    SELECT @Target=CONVERT(xml,t.target_data)
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t ON t.event_session_address=s.address
    WHERE s.name=N'alwayson_health' AND t.target_name=N'event_file';
    SET @Active=@Target.value('(EventFileTarget/File/@name)[1]','nvarchar(4000)');

    IF @XelPattern IS NULL AND @Configured IS NOT NULL
    BEGIN
        -- Configured filenames can be relative to SQL Server's log directory.
        SET @Configured=REPLACE(@Configured,N'\',N'/');
        SET @Active=REPLACE(@Active,N'\',N'/');
        IF CHARINDEX(N'/',@Configured)=0
        BEGIN
            IF CHARINDEX(N'/',@Active)>0
                SET @Configured=LEFT(@Active,LEN(@Active)-CHARINDEX(N'/',REVERSE(@Active))+1)+@Configured;
            ELSE SET @Configured=NULL;
        END;
        IF @Configured IS NOT NULL
            SET @XelPattern=CASE WHEN RIGHT(LOWER(@Configured),4)=N'.xel'
                THEN LEFT(@Configured,LEN(@Configured)-4)+N'*.xel'
                ELSE @Configured+N'*.xel' END;
    END;

    IF @XelPattern IS NULL
    BEGIN
        SELECT @ServerName AS ReportingServer, 'UNKNOWN' AS Status,
          @SessionRunning AS AlwaysOnHealthRunning,
          'Cannot resolve event-file path. Supply @XelPattern using the full server-side path.' AS Finding;
        RETURN;
    END;

    IF OBJECT_ID('tempdb..#AGHistoryRaw') IS NOT NULL DROP TABLE #AGHistoryRaw;
    IF OBJECT_ID('tempdb..#AGRoleHistory') IS NOT NULL DROP TABLE #AGRoleHistory;
    SELECT CONVERT(xml,event_data) AS EventXML, file_name, file_offset
    INTO #AGHistoryRaw
    FROM sys.fn_xe_file_target_read_file(@XelPattern,NULL,NULL,NULL);

    ;WITH X AS
    (
       SELECT EventXML,
          EventXML.value('(event/@name)[1]','nvarchar(128)') AS EventName,
          CONVERT(datetime2(7),SWITCHOFFSET(
             EventXML.value('(event/@timestamp)[1]','datetimeoffset(7)'),'+00:00')) AS EventUTC
       FROM #AGHistoryRaw
    )
    SELECT x.EventUTC,
       TRY_CONVERT(uniqueidentifier,x.EventXML.value('(event/data[@name="availability_group_id"]/value)[1]','nvarchar(100)')) AS GroupID,
       TRY_CONVERT(uniqueidentifier,x.EventXML.value('(event/data[@name="availability_replica_id"]/value)[1]','nvarchar(100)')) AS ReplicaID,
       x.EventXML.value('(event/data[@name="availability_group_name"]/value)[1]','nvarchar(128)') AS AGName,
       COALESCE(NULLIF(x.EventXML.value('(event/data[@name="previous_state"]/text)[1]','nvarchar(100)'),N''),pm.map_value) AS PreviousState,
       COALESCE(NULLIF(x.EventXML.value('(event/data[@name="current_state"]/text)[1]','nvarchar(100)'),N''),cm.map_value) AS CurrentState
    INTO #AGRoleHistory
    FROM X x
    OUTER APPLY (SELECT TOP (1) map_value FROM sys.dm_xe_map_values
       WHERE name=N'availability_replica_state' AND map_key=TRY_CONVERT(int,
         x.EventXML.value('(event/data[@name="previous_state"]/value)[1]','nvarchar(30)'))) pm
    OUTER APPLY (SELECT TOP (1) map_value FROM sys.dm_xe_map_values
       WHERE name=N'availability_replica_state' AND map_key=TRY_CONVERT(int,
         x.EventXML.value('(event/data[@name="current_state"]/value)[1]','nvarchar(30)'))) cm
    WHERE x.EventName=N'availability_replica_state_change' AND x.EventUTC<=@WindowEndUTC;

    -- 1. Capture/window context. Retention coverage is not proof of continuity.
    SELECT @ServerName AS ReportingServer, @WindowStartUTC AS WindowStartUTC,
       @WindowEndUTC AS WindowEndUTC_SaveForNextCheck,
       CASE WHEN @LastChecked IS NULL THEN 'Previous weekday midnight UK (overlap window)'
            ELSE 'Explicit previous check timestamp' END AS WindowBasis,
       @WindowStartUTC AT TIME ZONE 'UTC' AT TIME ZONE 'GMT Standard Time' AS WindowStartUK,
       @SessionRunning AS AlwaysOnHealthRunning, @StateEventConfigured AS StateChangeEventConfigured,
       @XelPattern AS FilesRead,
       MIN(EventXML.value('(event/@timestamp)[1]','datetimeoffset(7)')) AS OldestRetainedEventUTC,
       MAX(EventXML.value('(event/@timestamp)[1]','datetimeoffset(7)')) AS NewestRetainedEventUTC,
       COUNT_BIG(*) AS RetainedEvents,
       'No matching events is not proof of no failover. Read files on every replica.' AS EvidenceLimit
    FROM #AGHistoryRaw;

    -- 2. Current LOCAL role and last observed entry, across all retained history.
    SELECT @ServerName AS ReportingServer, ag.name AS AGName, ar.replica_server_name AS LocalReplica,
       rs.role_desc AS CurrentLocalRole, rs.operational_state_desc AS CurrentOperationalState,
       p.EventUTC AS LastObservedPrimaryNormalUTC,
       p.EventUTC AT TIME ZONE 'UTC' AT TIME ZONE 'GMT Standard Time' AS LastObservedPrimaryNormalUK,
       latest.CurrentState AS LatestRetainedLocalState,
       CASE WHEN p.EventUTC IS NULL THEN 'UNKNOWN - primary entry absent from retained files'
            WHEN rs.role<>1 THEN 'Historical primary entry; replica is not primary now'
            WHEN UPPER(latest.CurrentState)<>N'PRIMARY_NORMAL' THEN 'Current state differs from latest retained event; history incomplete or capture pending'
            ELSE 'Latest observed primary-role activation; not guaranteed continuous tenure start'
       END AS Interpretation,
       (SELECT COUNT_BIG(*) FROM #AGRoleHistory h
        WHERE h.GroupID=ag.group_id AND h.ReplicaID=ar.replica_id
          AND UPPER(h.CurrentState)=N'PRIMARY_NORMAL'
          AND h.EventUTC>@WindowStartUTC AND h.EventUTC<=@WindowEndUTC) AS PrimaryNormalEntriesSinceLastCheck
    FROM sys.availability_groups ag
    JOIN sys.availability_replicas ar ON ar.group_id=ag.group_id
    JOIN sys.dm_hadr_availability_replica_states rs
      ON rs.replica_id=ar.replica_id AND rs.group_id=ag.group_id AND rs.is_local=1
    OUTER APPLY (SELECT TOP (1) h.EventUTC FROM #AGRoleHistory h
       WHERE h.GroupID=ag.group_id AND h.ReplicaID=ar.replica_id
         AND UPPER(h.CurrentState)=N'PRIMARY_NORMAL' ORDER BY h.EventUTC DESC) p
    OUTER APPLY (SELECT TOP (1) h.CurrentState FROM #AGRoleHistory h
       WHERE h.GroupID=ag.group_id AND h.ReplicaID=ar.replica_id ORDER BY h.EventUTC DESC) latest
    WHERE @AGName IS NULL OR ag.name=@AGName;

    -- 3. All role transitions since last check, including AGs no longer configured.
    SELECT @ServerName AS ReportingServer, h.AGName, h.ReplicaID,
       h.EventUTC, h.EventUTC AT TIME ZONE 'UTC' AT TIME ZONE 'GMT Standard Time' AS EventUK,
       h.PreviousState, h.CurrentState, priorrole.CurrentState AS PreviousObservedStableRole,
       CASE WHEN UPPER(h.CurrentState)=N'PRIMARY_NORMAL' AND
             (UPPER(h.PreviousState)=N'SECONDARY_NORMAL' OR UPPER(priorrole.CurrentState)=N'SECONDARY_NORMAL')
              THEN 'Secondary-to-primary activation observed; corroborate peer/cluster logs for failover outcome'
            WHEN UPPER(h.CurrentState)=N'PRIMARY_NORMAL'
              THEN 'Primary activation observed; failover versus restart/creation not established'
            ELSE 'Intermediate/secondary role transition; not proof of failed failover'
       END AS Evidence
    FROM #AGRoleHistory h
    OUTER APPLY (SELECT TOP (1) old.CurrentState FROM #AGRoleHistory old
       WHERE old.GroupID=h.GroupID AND old.ReplicaID=h.ReplicaID AND old.EventUTC<h.EventUTC
         AND UPPER(old.CurrentState) IN (N'PRIMARY_NORMAL',N'SECONDARY_NORMAL')
       ORDER BY old.EventUTC DESC) priorrole
    WHERE h.EventUTC>@WindowStartUTC AND h.EventUTC<=@WindowEndUTC
      AND (@AGName IS NULL OR h.AGName=@AGName)
    ORDER BY h.EventUTC,h.AGName;

    -- 4. Failover validation / lease events. Inspect full XML; presence alone
    -- does not establish failed failover or exclude a subsequent successful retry.
    SELECT @ServerName AS ReportingServer,
       e.EventXML.value('(event/@timestamp)[1]','datetimeoffset(7)') AS EventUTC,
       e.EventXML.value('(event/@name)[1]','nvarchar(128)') AS EventName,
       e.EventXML.value('(event/data[@name="availability_group_name"]/value)[1]','nvarchar(128)') AS AGName,
       e.EventXML AS EvidenceXML
    FROM #AGHistoryRaw e
    WHERE e.EventXML.value('(event/@name)[1]','nvarchar(128)') IN
      (N'availability_replica_automatic_failover_validation',N'availability_group_lease_expired')
      AND e.EventXML.value('(event/@timestamp)[1]','datetimeoffset(7)')>@WindowStartUTC AT TIME ZONE 'UTC'
      AND e.EventXML.value('(event/@timestamp)[1]','datetimeoffset(7)')<=@WindowEndUTC AT TIME ZONE 'UTC'
      AND (@AGName IS NULL OR e.EventXML.value('(event/data[@name="availability_group_name"]/value)[1]','nvarchar(128)')=@AGName)
    ORDER BY EventUTC;

    DROP TABLE #AGRoleHistory;
    DROP TABLE #AGHistoryRaw;
END TRY
BEGIN CATCH
    SELECT @ServerName AS ReportingServer, 'UNKNOWN - history could not be read' AS Status,
       @XelPattern AS FilesRead, ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS Finding;
END CATCH;
