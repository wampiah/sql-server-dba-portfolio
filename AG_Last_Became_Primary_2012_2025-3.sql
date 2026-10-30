/*
SQL Server 2012-2025. Read-only; run the ENTIRE script in master on each replica.
Uses batch-scoped table variables to avoid earlier #temp-table column bindings.
Returns REAL timestamp records from both XE and every retained SQL error log.
One row per AG/source when a primary-entry record exists. Last_became_primary
is datetime2 NOT NULL. If neither source retains a record, no dated row can
be returned: the server/AG is identified in the SSMS Messages tab instead.
Two source rows can describe the same activation; they are NOT two failovers.
XE time is UTC; error-log time is server-local and is not silently converted.
SQL startup is context only, never a replacement date. A PRIMARY_NORMAL entry
may follow restart/rejoin; it does not establish cross-node failover or
continuous primary tenure. Error-log matching recognises English messages.
Historical error-log AG names may refer to a recreated AG with the same name.
*/
USE master;
SET NOCOUNT ON;

DECLARE @XelPattern nvarchar(4000) = NULL; -- optional full server-side *.xel path
DECLARE @NowUTC datetime2(7) = SYSUTCDATETIME();
DECLARE @Configured nvarchar(4000), @CurrentFile nvarchar(4000);
DECLARE @Directory nvarchar(4000), @Target xml;
DECLARE @HistoryStatus nvarchar(2048) = N'XE read completed';

DECLARE @LastPrimary TABLE
(
    group_id uniqueidentifier,
    replica_id uniqueidentifier,
    last_became_primary_utc datetime2(7),
    source_file nvarchar(4000),
    source_record nvarchar(max)
);

BEGIN TRY
    -- Resolve a full path: this also works on SQL Server 2012/2014.
    IF @XelPattern IS NULL
    BEGIN
        SELECT @Configured = CONVERT(nvarchar(4000), f.value)
        FROM sys.server_event_sessions s
        JOIN sys.server_event_session_targets t
          ON t.event_session_id = s.event_session_id
        JOIN sys.server_event_session_fields f
          ON f.event_session_id = t.event_session_id
         AND f.object_id = t.target_id
        WHERE LOWER(s.name) = N'alwayson_health'
          AND t.name = N'event_file' AND f.name = N'filename';

        SELECT @Target = CONVERT(xml, t.target_data)
        FROM sys.dm_xe_sessions s
        JOIN sys.dm_xe_session_targets t
          ON t.event_session_address = s.address
        WHERE LOWER(s.name) = N'alwayson_health'
          AND t.target_name = N'event_file';

        IF @Target IS NOT NULL
            SET @CurrentFile = @Target.value(
                '(EventFileTarget/File/@name)[1]', 'nvarchar(4000)');

        SET @CurrentFile = REPLACE(COALESCE(@CurrentFile,
            CONVERT(nvarchar(4000), SERVERPROPERTY('ErrorLogFileName'))), N'\', N'/');

        IF CHARINDEX(N'/', @CurrentFile) > 0
            SET @Directory = LEFT(@CurrentFile,
                LEN(@CurrentFile) - CHARINDEX(N'/', REVERSE(@CurrentFile)) + 1);

        SET @Configured = REPLACE(@Configured, N'\', N'/');
        IF @Configured IS NULL
            RAISERROR('alwayson_health file target not found. Set @XelPattern.', 16, 1);

        IF LEFT(@Configured, 1) <> N'/' AND SUBSTRING(@Configured, 2, 2) <> N':/'
            SET @Configured = @Directory + @Configured;

        SET @XelPattern = CASE WHEN RIGHT(LOWER(@Configured), 4) = N'.xel'
            THEN LEFT(@Configured, LEN(@Configured) - 4) + N'*.xel'
            ELSE @Configured + N'*.xel' END;
    END;

    IF @XelPattern IS NULL
        RAISERROR('Cannot resolve the XE file directory. Set @XelPattern.', 16, 1);

    ;WITH ev AS
    (
        SELECT CONVERT(xml, event_data) AS ed, file_name
        FROM sys.fn_xe_file_target_read_file(@XelPattern, NULL, NULL, NULL)
        WHERE object_name = N'availability_replica_state_change'
    ),
    p AS
    (
        SELECT
            CONVERT(datetime2(7), SWITCHOFFSET(
                ed.value('(event/@timestamp)[1]', 'datetimeoffset(7)'),
                '+00:00')) AS event_time_utc,
            TRY_CONVERT(uniqueidentifier,
                ed.value('(event/data[@name="availability_group_id"]/value)[1]',
                         'nvarchar(100)')) AS group_id,
            TRY_CONVERT(uniqueidentifier,
                ed.value('(event/data[@name="availability_replica_id"]/value)[1]',
                         'nvarchar(100)')) AS replica_id,
            COALESCE(
                NULLIF(ed.value('(event/data[@name="current_state"]/text)[1]',
                                'nvarchar(100)'), N''),
                m.map_value) AS current_state,
            file_name, CONVERT(nvarchar(max), ed) AS source_record
        FROM ev
        OUTER APPLY
        (
            SELECT TOP (1) map_value
            FROM sys.dm_xe_map_values
            WHERE name = N'availability_replica_state'
              AND map_key = TRY_CONVERT(int,
                  ed.value('(event/data[@name="current_state"]/value)[1]',
                           'nvarchar(30)'))
        ) m
    ),
    ranked AS
    (
        SELECT *, ROW_NUMBER() OVER
            (PARTITION BY group_id, replica_id ORDER BY event_time_utc DESC) AS rn
        FROM p
        WHERE UPPER(current_state) = N'PRIMARY_NORMAL'
          AND group_id IS NOT NULL AND replica_id IS NOT NULL
          AND event_time_utc <= @NowUTC
    )
    INSERT @LastPrimary(group_id, replica_id, last_became_primary_utc, source_file, source_record)
    SELECT group_id, replica_id, event_time_utc, file_name, source_record
    FROM ranked WHERE rn = 1;
END TRY
BEGIN CATCH
    SET @HistoryStatus = LEFT(N'XE history unavailable: ' + ERROR_MESSAGE(), 2048);
END CATCH;

-- Read ALL retained SQL error logs, not just the current file or six archives.
DECLARE @LogFiles TABLE(ArchiveNo int, LogDate datetime, LogSize bigint);
DECLARE @OneLog TABLE(LogDate datetime, ProcessInfo nvarchar(50), LogText nvarchar(max));
DECLARE @PrimaryLogs TABLE(ArchiveNo int, LogDate datetime, LogText nvarchar(max));
DECLARE @ActualPrimaryDates TABLE
(
    server_name nvarchar(128), ag_name sysname, replica_name nvarchar(256),
    current_role nvarchar(60), last_became_primary datetime2(7) NOT NULL,
    time_basis nvarchar(20), data_source nvarchar(20),
    source_file nvarchar(4000), source_record nvarchar(max), sql_start_time datetime2(7)
);
DECLARE @ReportingServer nvarchar(128)=CONVERT(nvarchar(128),SERVERPROPERTY('ServerName'));
DECLARE @ArchiveNo int, @LogsRead int=0, @Message nvarchar(4000);
DECLARE @SqlStartTime datetime2(7), @MissingAG sysname;
DECLARE @ErrorLogFile nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('ErrorLogFileName'));

IF @HistoryStatus<>N'XE read completed'
BEGIN
    SET @Message=CONCAT(@ReportingServer,N': ',@HistoryStatus);
    PRINT @Message;
END;

BEGIN TRY
    INSERT @LogFiles EXEC master.sys.sp_enumerrorlogs;
END TRY
BEGIN CATCH
    SET @Message=CONCAT(@ReportingServer,N': error-log enumeration failed: ',ERROR_MESSAGE(),
        N'. Attempting current log only.');
    PRINT @Message;
END CATCH;
IF NOT EXISTS(SELECT 1 FROM @LogFiles) INSERT @LogFiles VALUES(0,NULL,NULL);

WHILE EXISTS(SELECT 1 FROM @LogFiles)
BEGIN
    SELECT @ArchiveNo=MIN(ArchiveNo) FROM @LogFiles;
    BEGIN TRY
        DELETE FROM @OneLog;
        INSERT @OneLog EXEC master.sys.sp_readerrorlog @ArchiveNo,1,N'PRIMARY_NORMAL';
        INSERT @PrimaryLogs(ArchiveNo,LogDate,LogText)
        SELECT @ArchiveNo,LogDate,LogText FROM @OneLog
        WHERE CHARINDEX(N'has changed from',LogText COLLATE DATABASE_DEFAULT)>0
          AND CHARINDEX(N' to ''PRIMARY_NORMAL''',LogText COLLATE DATABASE_DEFAULT)>0;
        SET @LogsRead=@LogsRead+1;
    END TRY
    BEGIN CATCH
        SET @Message=CONCAT(@ReportingServer,N': failed to read error log ',@ArchiveNo,N': ',ERROR_MESSAGE());
        PRINT @Message;
    END CATCH;
    DELETE FROM @LogFiles WHERE ArchiveNo=@ArchiveNo;
END;

-- Current role comes directly from local replica DMVs, not from historical text.
DECLARE @LocalReplicas TABLE
(
    group_id uniqueidentifier, ag_name sysname, replica_id uniqueidentifier,
    replica_name nvarchar(256), current_role nvarchar(60)
);
SELECT @SqlStartTime=sqlserver_start_time FROM sys.dm_os_sys_info;
INSERT @LocalReplicas(group_id,ag_name,replica_id,replica_name,current_role)
SELECT ag.group_id,ag.name AS ag_name,ar.replica_id,
    ar.replica_server_name AS replica_name,rs.role_desc AS current_role
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states rs
  ON rs.group_id=ag.group_id AND rs.is_local=1
JOIN sys.availability_replicas ar
  ON ar.group_id=ag.group_id AND ar.replica_id=rs.replica_id;

-- Actual XE timestamp, with its original XML and file name.
INSERT @ActualPrimaryDates
SELECT @ReportingServer,l.ag_name,l.replica_name,l.current_role,
    x.last_became_primary_utc,N'UTC',N'XE',x.source_file,x.source_record,@SqlStartTime
FROM @LocalReplicas l
JOIN @LastPrimary x ON x.group_id=l.group_id AND x.replica_id=l.replica_id;

-- Actual SQL error-log timestamp, with exact original message and archive.
-- Keep this in SERVER LOCAL time; do not mix its ordering with UTC XE dates.
INSERT @ActualPrimaryDates
SELECT @ReportingServer,l.ag_name,l.replica_name,l.current_role,
    e.LogDate,N'SERVER LOCAL',N'SQL ERROR LOG',
    CONCAT(@ErrorLogFile,CASE WHEN e.ArchiveNo>0 THEN N'.'+CONVERT(nvarchar(10),e.ArchiveNo) ELSE N'' END),
    e.LogText,@SqlStartTime
FROM @LocalReplicas l
CROSS APPLY
(
    SELECT TOP(1) p.ArchiveNo,p.LogDate,p.LogText
    FROM @PrimaryLogs p
    WHERE p.LogDate IS NOT NULL AND
      CHARINDEX(N'availability group '''+l.ag_name+N'''',p.LogText COLLATE DATABASE_DEFAULT)>0
    ORDER BY p.LogDate DESC,p.ArchiveNo
) e;

-- Missing evidence is reported explicitly in Messages, never given a fake date.
DECLARE missing_evidence CURSOR LOCAL FAST_FORWARD FOR
SELECT l.ag_name FROM @LocalReplicas l
WHERE NOT EXISTS(SELECT 1 FROM @ActualPrimaryDates d
    WHERE d.ag_name COLLATE DATABASE_DEFAULT=l.ag_name
      AND d.replica_name COLLATE DATABASE_DEFAULT=l.replica_name);
OPEN missing_evidence;
FETCH NEXT FROM missing_evidence INTO @MissingAG;
WHILE @@FETCH_STATUS=0
BEGIN
    SET @Message=CONCAT(@ReportingServer,N' / ',@MissingAG,
      N': no dated row returned. No matching primary-entry event was recovered from readable retained XE/error logs.');
    PRINT @Message;
    FETCH NEXT FROM missing_evidence INTO @MissingAG;
END;
CLOSE missing_evidence;
DEALLOCATE missing_evidence;
SET @Message=CONCAT(@ReportingServer,N': error logs successfully read=',@LogsRead,
    N'. Source dates are reported separately; two rows can describe the same activation.');
PRINT @Message;

-- One stable result set for Registered Servers. Every returned date is a
-- real recorded timestamp. Review Messages for every server without a row.
SELECT server_name,ag_name,replica_name,current_role,last_became_primary,
    time_basis,data_source,source_file,source_record,sql_start_time
FROM @ActualPrimaryDates
ORDER BY CASE WHEN current_role=N'PRIMARY' THEN 0 ELSE 1 END,
    ag_name,replica_name,data_source;
