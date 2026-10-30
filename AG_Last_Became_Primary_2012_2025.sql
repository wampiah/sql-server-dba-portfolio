/*
SQL Server 2012-2025. Read-only; run in master on each replica.
Last-primary outputs are TEXT so missing history can display UNKNOWN.
No restart date or fabricated date is substituted for a missing role event.
DaysAsPrimary is elapsed whole days since the latest retained activation;
only populated while the local replica is PRIMARY.
UK conversion uses current last-Sunday March/October rules (since 1996).
*/
USE master;
SET NOCOUNT ON;

DECLARE @XelPattern nvarchar(4000) = NULL; -- optional full server-side *.xel path
DECLARE @NowUTC datetime2(7) = SYSUTCDATETIME();
DECLARE @Configured nvarchar(4000), @CurrentFile nvarchar(4000);
DECLARE @Directory nvarchar(4000), @Target xml;
DECLARE @HistoryStatus nvarchar(2048) = N'XE read completed';

IF OBJECT_ID('tempdb..#LastPrimary') IS NOT NULL DROP TABLE #LastPrimary;
CREATE TABLE #LastPrimary
(
    group_id uniqueidentifier,
    replica_id uniqueidentifier,
    last_became_primary_utc datetime2(7)
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
        SELECT CONVERT(xml, event_data) AS ed
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
                m.map_value) AS current_state
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
    )
    INSERT #LastPrimary(group_id, replica_id, last_became_primary_utc)
    SELECT group_id, replica_id, MAX(event_time_utc)
    FROM p
    WHERE UPPER(current_state) = N'PRIMARY_NORMAL'
      AND group_id IS NOT NULL AND replica_id IS NOT NULL
      AND event_time_utc <= @NowUTC
    GROUP BY group_id, replica_id;
END TRY
BEGIN CATCH
    SET @HistoryStatus = LEFT(N'XE history unavailable: ' + ERROR_MESSAGE(), 2048);
END CATCH;

SELECT
    ag.name AS ag_name,
    ar.replica_server_name AS replica_name,
    rs.role_desc AS current_role,
    COALESCE(CONVERT(nvarchar(33), lp.last_became_primary_utc, 126),
             N'UNKNOWN') AS last_became_primary_utc,
    COALESCE(CONVERT(nvarchar(40),
        SWITCHOFFSET(TODATETIMEOFFSET(lp.last_became_primary_utc, '+00:00'),
            CASE WHEN lp.last_became_primary_utc >= bounds.bst_start_utc
                   AND lp.last_became_primary_utc < bounds.bst_end_utc
                 THEN '+01:00' ELSE '+00:00' END), 127),
        N'UNKNOWN') AS last_became_primary_uk,
    CASE
        WHEN rs.role <> 1 THEN N'N/A - not primary'
        WHEN lp.last_became_primary_utc IS NULL THEN N'UNKNOWN'
        ELSE CONVERT(nvarchar(30),
            DATEDIFF(day, lp.last_became_primary_utc, @NowUTC)
            - CASE WHEN DATEADD(day,
                DATEDIFF(day, lp.last_became_primary_utc, @NowUTC),
                lp.last_became_primary_utc) > @NowUTC THEN 1 ELSE 0 END)
    END AS days_as_primary,
    (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) AS sql_start_time,
    CASE
        WHEN @HistoryStatus <> N'XE read completed' THEN @HistoryStatus
        WHEN lp.last_became_primary_utc IS NULL
            THEN N'UNKNOWN - no matching primary-entry event in retained XE files'
        ELSE N'Latest retained PRIMARY_NORMAL entry; may follow restart/rejoin'
    END AS primary_date_evidence
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states rs
  ON rs.group_id = ag.group_id AND rs.is_local = 1
JOIN sys.availability_replicas ar
  ON ar.group_id = ag.group_id AND ar.replica_id = rs.replica_id
LEFT JOIN #LastPrimary lp
  ON lp.group_id = ag.group_id AND lp.replica_id = ar.replica_id
OUTER APPLY
(
    SELECT DATEFROMPARTS(YEAR(lp.last_became_primary_utc), 3, 31) AS march31,
           DATEFROMPARTS(YEAR(lp.last_became_primary_utc), 10, 31) AS october31
) calendar
OUTER APPLY
(
    SELECT
        DATEADD(hour, 1, CONVERT(datetime2(7), DATEADD(day,
            -((DATEDIFF(day, CONVERT(date, '19000107', 112), calendar.march31) % 7 + 7) % 7),
            calendar.march31))) AS bst_start_utc,
        DATEADD(hour, 1, CONVERT(datetime2(7), DATEADD(day,
            -((DATEDIFF(day, CONVERT(date, '19000107', 112), calendar.october31) % 7 + 7) % 7),
            calendar.october31))) AS bst_end_utc
) bounds
-- WHERE rs.role = 1 -- enable for current primary replicas only
ORDER BY CASE WHEN rs.role = 1 THEN 0 ELSE 1 END, ag.name, ar.replica_server_name;
