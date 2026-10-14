/* DBA DAILY CHECKS v1.11 | SQL Server 2012-2022 and Azure SQL Managed Instance
   Run once per instance in SSMS, preferably first against one server.
   No persistent writes or maintenance. Uses session temp tables only.
   UTC window for XE; backup/job/CommandLog times use server-local GETDATE().
   No NOLOCK: reads can still consume resources and briefly take metadata locks.
   Restore tests run in the test environment; their evidence is reviewed separately.
   Alert review and recovery policy validation remain separate.
*/
SET NOCOUNT ON;
DECLARE @OldLockTimeout int = @@LOCK_TIMEOUT;
DECLARE @Hours int=24, @BlockingSeconds int=60,
        @DataBackupMaxAgeHours int=48, -- overdue threshold, independent of @Hours
        @DataBackupMode varchar(10)='FULL_DIFF', -- FULL_DIFF = latest full/differential; FULL = full only
        @ExceptionsOnly bit=0, -- 1 = output CRITICAL, ATTENTION, REVIEW and NOT CHECKED only
        @DiskWarningPct decimal(5,2)=15, @DiskCriticalPct decimal(5,2)=10,
        @FileUsedWarningPct decimal(5,2)=90,
        @QueueWarningMB int=1024, -- review thresholds locally before use
        @MaintenanceDatabase sysname=N'MaintenanceDB', -- Ola CommandLog source, excluded from database-level results
        @IntegrityMaxAgeDays int=7, -- illustrative: last good CHECKDB older than this = ATTENTION; set to your policy
        @ReadErrorLogs bit=0, @ErrorLogArchives int=6,
        @ReadDeadlockFiles bit=0, -- opt-in: retained XE files can be expensive
        @XePattern nvarchar(4000)=NULL; -- optional explicit server-side *.xel path
DECLARE @Now datetime=GETDATE(), @Utc datetime2=SYSUTCDATETIME(),
        @Since datetime, @SinceUtc datetime2,
        @Server nvarchar(256)=CONVERT(nvarchar(256),SERVERPROPERTY('ServerName')),
        @Engine int=CONVERT(int,SERVERPROPERTY('EngineEdition')),
        @IsHadrEnabled int=CONVERT(int,SERVERPROPERTY('IsHadrEnabled'));
SET @Since=DATEADD(hour,-@Hours,@Now); SET @SinceUtc=DATEADD(hour,-@Hours,@Utc);
-- NULL would make every 'name<>@x' test unknown and silently empty the database checks.
SET @MaintenanceDatabase=ISNULL(@MaintenanceDatabase,N'');
-- EDIT EXCLUSIONS HERE. Names must match SERVERPROPERTY('ServerName'), not registration aliases.
IF OBJECT_ID('tempdb..#ExcludedServers') IS NOT NULL DROP TABLE #ExcludedServers;
CREATE TABLE #ExcludedServers(ServerName nvarchar(256) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
-- Examples only: uncomment and replace with your actual instance names.
-- INSERT INTO #ExcludedServers(ServerName) VALUES (N'SQL-DEV01'),(N'SQL-OLD01\INSTANCE1');

IF OBJECT_ID('tempdb..#ExcludedDatabases') IS NOT NULL DROP TABLE #ExcludedDatabases;
CREATE TABLE #ExcludedDatabases
 (DatabaseName nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
  ServerName nvarchar(256) COLLATE DATABASE_DEFAULT NULL);
-- NULL server = exclude this database name on every instance.
-- INSERT INTO #ExcludedDatabases(DatabaseName,ServerName) VALUES (N'ObsoleteDatabase',NULL);
-- Specify a server to exclude the database only on that instance.
-- INSERT INTO #ExcludedDatabases(DatabaseName,ServerName) VALUES (N'TestDatabase',N'SQL-PROD01');

IF EXISTS(SELECT 1 FROM #ExcludedServers WHERE ServerName=@Server COLLATE DATABASE_DEFAULT)
BEGIN
 SELECT @Utc CheckTimeUtc,@Server ServerName,CAST(@Server AS nvarchar(512)) Resource,
 CAST(N'Server exclusion' AS nvarchar(100)) CheckName,CAST('N/A' AS varchar(20)) Status,
 CAST(N'Instance intentionally excluded; daily checks skipped.' AS nvarchar(max)) Finding,
 CAST(N'Explicit #ExcludedServers match; script version=1.11' AS nvarchar(max)) Evidence,
 CAST(NULL AS nvarchar(100)) Ticket,CAST(NULL AS nvarchar(100)) Owner,CAST(NULL AS nvarchar(100)) NextUpdate;
 RETURN; -- before monitoring, policy checks or changing LOCK_TIMEOUT
END;
IF OBJECT_ID('tempdb..#OmittedDatabases') IS NOT NULL DROP TABLE #OmittedDatabases;
CREATE TABLE #OmittedDatabases(DatabaseName nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
INSERT INTO #OmittedDatabases(DatabaseName)
 SELECT DISTINCT DatabaseName FROM #ExcludedDatabases
 WHERE ServerName IS NULL OR ServerName=@Server COLLATE DATABASE_DEFAULT;

IF @Hours<1 OR @Hours>168 THROW 50000,'Hours must be between 1 and 168.',1;
IF @Engine IN (5,6) THROW 50000,'Use the Azure SQL Database script for SQL Database; Synapse is outside scope.',1;
IF @DataBackupMaxAgeHours<1 OR @DataBackupMaxAgeHours>8760 THROW 50000,'Data backup age must be between 1 and 8760 hours.',1;
IF @DataBackupMode NOT IN ('FULL','FULL_DIFF') THROW 50000,'DataBackupMode must be FULL or FULL_DIFF.',1;
DECLARE @CanMonitor bit=CASE WHEN HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER STATE')=1
 OR HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER PERFORMANCE STATE')=1 THEN 1 ELSE 0 END;
SET LOCK_TIMEOUT 3000;
IF OBJECT_ID('tempdb..#Daily') IS NOT NULL DROP TABLE #Daily;
CREATE TABLE #Daily(CheckTimeUtc datetime2, ServerName nvarchar(256), Resource nvarchar(512),
 CheckName nvarchar(100), Status varchar(20), Finding nvarchar(max), Evidence nvarchar(max));
IF OBJECT_ID('tempdb..#BackupPolicy') IS NOT NULL DROP TABLE #BackupPolicy;
CREATE TABLE #BackupPolicy(DatabaseName sysname PRIMARY KEY, FullMaxAgeHours int NOT NULL,
 DifferentialMaxAgeHours int NULL, LogMaxAgeMinutes int NULL);
/* Fill with YOUR approved policy. FullMaxAgeHours must allow your full schedule.
   Example only: INSERT #BackupPolicy VALUES(N'YourDatabase',192,30,30);
   Leave LogMaxAgeMinutes NULL for SIMPLE databases. No policy = REVIEW.
   History is local to this instance; AG backups on other replicas are not combined.
*/
IF OBJECT_ID('tempdb..#JobPolicy') IS NOT NULL DROP TABLE #JobPolicy;
CREATE TABLE #JobPolicy(JobName sysname PRIMARY KEY, MaxSuccessAgeHours int NOT NULL,
 MaxRunningMinutes int NOT NULL);
/* Example only: INSERT #JobPolicy VALUES(N'Your daily job',30,180);
   Include only jobs expected to run on THIS replica; account for schedules/holidays.
*/
-- Known continuous RESTORING periods: suppress only Database state rows after seven days.
-- Do not use database create_date or last restore-history date as a state start date.
IF OBJECT_ID('tempdb..#RestoringExceptions') IS NOT NULL DROP TABLE #RestoringExceptions;
CREATE TABLE #RestoringExceptions
 (DatabaseName nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
  ServerName nvarchar(256) COLLATE DATABASE_DEFAULT NULL,
  RestoringSinceUtc datetime2 NOT NULL);
-- Example only: replace names and use the verified UTC start of the current RESTORING period.
-- NULL server means all instances with that database name; prefer an explicit instance.
-- INSERT INTO #RestoringExceptions(DatabaseName,ServerName,RestoringSinceUtc)
-- VALUES (N'LongTermRestore',N'SQL-PROD01','2026-10-01T08:00:00');

-- Optional database-to-backup-job mapping; avoids guessing from job names.
IF OBJECT_ID('tempdb..#BackupJobs') IS NOT NULL DROP TABLE #BackupJobs;
CREATE TABLE #BackupJobs
 (DatabaseName nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
  ServerName nvarchar(256) COLLATE DATABASE_DEFAULT NULL,
  JobName nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL);
-- One job may be mapped to several databases; a failed job does not prove each database failed.
-- INSERT INTO #BackupJobs(DatabaseName,ServerName,JobName)
-- VALUES (N'ProductionDatabase',N'SQL-PROD01',N'DatabaseBackup - USER_DATABASES - FULL');

INSERT INTO #Daily
 (CheckTimeUtc,ServerName,Resource,CheckName,Status,Finding,Evidence)
VALUES
 (@Utc,@Server,@Server,N'Collection scope','INFO',
  N'Connected successfully. Current-state checks plus retained history; not an uptime guarantee.',
  CONCAT(N'Version=',CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion')),
   N'; engine=',@Engine,
   N'; server-local window=',CONVERT(varchar(30),@Since,126),N' to ',CONVERT(varchar(30),@Now,126),
   N'; UTC window=',CONVERT(varchar(30),@SinceUtc,126),N' to ',CONVERT(varchar(30),@Utc,126),
   N'; database scope=user databases except ',@MaintenanceDatabase,
   N'; additional excluded database names=',(SELECT COUNT(*) FROM #OmittedDatabases),
   N'; script version=1.11'));

-- 01 Database inventory: permissions must cover ALL databases to call coverage complete.
BEGIN TRY
 IF ISNULL(HAS_PERMS_BY_NAME(NULL,NULL,'VIEW ANY DATABASE'),0)<>1
  INSERT #Daily VALUES(@Utc,@Server,@Server,'Database inventory','NOT CHECKED','VIEW ANY DATABASE missing; inventory may be incomplete.',NULL);
 ELSE
  INSERT #Daily SELECT @Utc,@Server,name,'Database state',
   CASE WHEN state_desc='ONLINE' THEN 'PASS' ELSE 'ATTENTION' END,
   CONCAT('State=',state_desc COLLATE DATABASE_DEFAULT,
          '; recovery=',recovery_model_desc COLLATE DATABASE_DEFAULT,'; read_only=',is_read_only),
   'sys.databases; compare non-ONLINE states with approved exceptions'
  FROM sys.databases d WHERE d.database_id>4 AND d.name<>@MaintenanceDatabase
  AND NOT EXISTS(SELECT 1 FROM #OmittedDatabases x WHERE x.DatabaseName=d.name COLLATE DATABASE_DEFAULT)
  AND NOT (d.state=1 AND EXISTS(SELECT 1 FROM #RestoringExceptions r
   WHERE r.DatabaseName=d.name COLLATE DATABASE_DEFAULT
   AND (r.ServerName IS NULL OR r.ServerName=@Server COLLATE DATABASE_DEFAULT)
   AND r.RestoringSinceUtc<DATEADD(day,-7,@Utc)));
 EXEC sp_executesql N'INSERT #Daily SELECT @u,@s,@s,''Instance start'',
   CASE WHEN sqlserver_start_time>=@since THEN ''REVIEW'' ELSE ''INFO'' END,
   CONCAT(''SQL start (server local)='',CONVERT(varchar(30),sqlserver_start_time,126)),
   ''sys.dm_os_sys_info; REVIEW = restart inside the window; latest start only, not restart history'' FROM sys.dm_os_sys_info;',
   N'@u datetime2,@s nvarchar(256),@since datetime',@Utc,@Server,@Since;
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Database inventory and start','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;

-- 02 Backup age: default latest successful full/differential older than 48 hours.
-- Optional explicit policy and mapped-job failure evidence remain local to this instance.
BEGIN TRY
 IF ISNULL(HAS_PERMS_BY_NAME(NULL,NULL,'VIEW ANY DATABASE'),0)<>1
  RAISERROR('Inventory visibility insufficient for backup coverage.',16,1);
 EXEC sp_executesql N'
 SELECT database_name,
 MAX(CASE WHEN type=''D'' AND is_copy_only=0 THEN backup_finish_date END) FullTime,
 MAX(CASE WHEN type=''I'' THEN backup_finish_date END) DiffTime,
 MAX(CASE WHEN type=''L'' THEN backup_finish_date END) LogTime,
 MAX(CASE WHEN (type=''D'' AND is_copy_only=0) OR (@mode=''FULL_DIFF'' AND type=''I'')
          THEN backup_finish_date END) DataTime
 INTO #BackupAgeEvidence FROM msdb.dbo.backupset
 WHERE backup_finish_date<=@n GROUP BY database_name;
 CREATE TABLE #MappedBackupFailures
 (DatabaseName nvarchar(128) COLLATE DATABASE_DEFAULT,
  JobName nvarchar(128) COLLATE DATABASE_DEFAULT,FailedStart datetime,Outcome int);
 DECLARE @JobEvidenceError nvarchar(4000)=NULL;
 IF @engine<>4 AND EXISTS(SELECT 1 FROM #BackupJobs WHERE ServerName IS NULL OR ServerName=@s COLLATE DATABASE_DEFAULT)
 BEGIN
 BEGIN TRY
  INSERT INTO #MappedBackupFailures(DatabaseName,JobName,FailedStart,Outcome)
  SELECT m.DatabaseName,m.JobName,msdb.dbo.agent_datetime(h.run_date,h.run_time),h.run_status
  FROM #BackupJobs m JOIN msdb.dbo.sysjobs j ON j.name COLLATE DATABASE_DEFAULT=m.JobName
  JOIN msdb.dbo.sysjobhistory h ON h.job_id=j.job_id
  WHERE (m.ServerName IS NULL OR m.ServerName=@s COLLATE DATABASE_DEFAULT)
  AND h.step_id=0 AND h.run_status IN(0,3) AND h.run_date>0
  AND msdb.dbo.agent_datetime(h.run_date,h.run_time)>=DATEADD(hour,-@age,@n)
  AND msdb.dbo.agent_datetime(h.run_date,h.run_time)<=@n;
 END TRY BEGIN CATCH
  SET @JobEvidenceError=ERROR_MESSAGE();
 END CATCH;
 END;
 INSERT INTO #Daily(CheckTimeUtc,ServerName,Resource,CheckName,Status,Finding,Evidence)
 SELECT @u,@s,d.name,''Backup freshness'',
 CASE WHEN b.DataTime IS NULL OR b.DataTime<DATEADD(hour,-@age,@n) THEN ''ATTENTION''
 WHEN p.DatabaseName IS NULL OR (d.recovery_model_desc<>''SIMPLE'' AND p.LogMaxAgeMinutes IS NULL) THEN ''REVIEW''
 WHEN b.FullTime IS NULL OR b.FullTime<DATEADD(hour,-p.FullMaxAgeHours,@n)
 OR (p.DifferentialMaxAgeHours IS NOT NULL AND (b.DiffTime IS NULL OR b.DiffTime<DATEADD(hour,-p.DifferentialMaxAgeHours,@n)))
 OR (d.recovery_model_desc<>''SIMPLE'' AND p.LogMaxAgeMinutes IS NOT NULL AND (b.LogTime IS NULL OR b.LogTime<DATEADD(minute,-p.LogMaxAgeMinutes,@n)))
 THEN ''ATTENTION'' ELSE ''PASS'' END,
 CONCAT(''Latest data backup='',COALESCE(CONVERT(varchar(30),b.DataTime,126),''none locally''),
 ''; age hours='',CASE WHEN b.DataTime IS NULL THEN ''unknown''
 ELSE CONVERT(varchar(30),CAST(DATEDIFF(minute,b.DataTime,@n)/60.0 AS decimal(18,2))) END,
 ''; limit hours='',@age,''; mode='',@mode,
 CASE WHEN b.DataTime IS NULL THEN ''; no successful qualifying backup visible''
 WHEN b.DataTime<DATEADD(hour,-@age,@n) THEN ''; data backup overdue'' ELSE ''; data backup within age limit'' END,
 CASE WHEN f.JobName IS NOT NULL THEN CONCAT(''; mapped job failed/cancelled='',f.JobName,
 ''; job outcome start='',CONVERT(varchar(30),f.FailedStart,126)) ELSE '''' END,
 CASE WHEN p.DatabaseName IS NULL THEN ''; no configured recovery policy''
 WHEN d.recovery_model_desc<>''SIMPLE'' AND p.LogMaxAgeMinutes IS NULL THEN ''; no log policy configured'' ELSE ''; recovery policy compared'' END),
 CONCAT(''Local msdb backup history; full='',COALESCE(CONVERT(varchar(30),b.FullTime,126),''none''),
 ''; diff='',COALESCE(CONVERT(varchar(30),b.DiffTime,126),''none''),
 ''; log='',COALESCE(CONVERT(varchar(30),b.LogTime,126),''none''),
 ''; mapped failure lookup='',CASE WHEN @engine=4 THEN ''Agent excluded on Express''
 WHEN @JobEvidenceError IS NOT NULL THEN @JobEvidenceError
 WHEN NOT EXISTS(SELECT 1 FROM #BackupJobs m WHERE m.DatabaseName=d.name COLLATE DATABASE_DEFAULT
   AND (m.ServerName IS NULL OR m.ServerName=@s COLLATE DATABASE_DEFAULT)) THEN ''no mapping supplied''
 ELSE ''retained local job outcomes within backup-age window; confirm job visibility'' END,
 ''; mapped failures after last qualifying backup are supporting evidence, not proof of cause; AG backups on other replicas need separate review'')
 FROM sys.databases d LEFT JOIN #BackupAgeEvidence b
 ON b.database_name COLLATE DATABASE_DEFAULT=d.name COLLATE DATABASE_DEFAULT
 LEFT JOIN #BackupPolicy p ON p.DatabaseName COLLATE DATABASE_DEFAULT=d.name COLLATE DATABASE_DEFAULT
 OUTER APPLY(SELECT TOP (1) x.JobName,x.FailedStart FROM #MappedBackupFailures x
  WHERE x.DatabaseName=d.name COLLATE DATABASE_DEFAULT
  AND (b.DataTime IS NULL OR x.FailedStart>b.DataTime)
  ORDER BY x.FailedStart DESC,x.JobName) f
 WHERE d.database_id>4 AND d.name<>@m AND d.state=0
 AND NOT EXISTS(SELECT 1 FROM #OmittedDatabases x WHERE x.DatabaseName=d.name COLLATE DATABASE_DEFAULT); ',
 N'@u datetime2,@s nvarchar(256),@n datetime,@m sysname,@age int,@mode varchar(10),@engine int',
 @Utc,@Server,@Now,@MaintenanceDatabase,@DataBackupMaxAgeHours,@DataBackupMode,@Engine;
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Backup freshness','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;

-- 02b Integrity: last good DBCC CHECKDB as recorded by SQL Server, independent of any maintenance solution.
BEGIN TRY
 INSERT #Daily SELECT @Utc,@Server,d.name,'Last good CHECKDB',
  CASE WHEN c.t IS NULL OR c.t<'19010101' THEN 'REVIEW'
       WHEN c.t<DATEADD(day,-@IntegrityMaxAgeDays,@Now) THEN 'ATTENTION' ELSE 'PASS' END,
  CONCAT('Last good CHECKDB (server local)=',COALESCE(CONVERT(varchar(30),NULLIF(c.t,'19000101'),126),'none recorded'),
   '; policy age days=',@IntegrityMaxAgeDays),
  'DATABASEPROPERTYEX LastGoodCheckDbTime; NULL/none on older versions or never checked; PHYSICAL_ONLY runs may not update it; AG secondaries need review'
 FROM sys.databases d CROSS APPLY (SELECT TRY_CONVERT(datetime,DATABASEPROPERTYEX(d.name,'LastGoodCheckDbTime'))) c(t)
 WHERE d.database_id>4 AND d.name<>@MaintenanceDatabase AND d.state=0
 AND NOT EXISTS(SELECT 1 FROM #OmittedDatabases x WHERE x.DatabaseName=d.name COLLATE DATABASE_DEFAULT);
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Last good CHECKDB','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;
BEGIN TRY
 EXEC sp_executesql N'
 DECLARE @n int=(SELECT COUNT(*) FROM msdb.dbo.suspect_pages sp
 WHERE sp.event_type IN(1,2,3) AND sp.last_update_date>=@since
 AND EXISTS(SELECT 1 FROM sys.databases d WHERE d.database_id=sp.database_id
            AND d.database_id>4 AND d.name<>@m
            AND NOT EXISTS(SELECT 1 FROM #OmittedDatabases x WHERE x.DatabaseName=d.name COLLATE DATABASE_DEFAULT)));
 INSERT #Daily VALUES(@u,@s,@s,''Suspect pages'',CASE WHEN @n>0 THEN ''ATTENTION'' ELSE ''PASS'' END,
 CONCAT(@n,'' suspect_pages rows for in-scope user databases (event types 1-3) updated in the window.''),
 ''msdb.dbo.suspect_pages; table is capped and cleared manually; PASS is not proof of no corruption'');',
 N'@u datetime2,@s nvarchar(256),@since datetime,@m sysname',@Utc,@Server,@Since,@MaintenanceDatabase;
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Suspect pages','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;

-- SQL Server Express (EngineEdition=4) has no SQL Server Agent.
-- Skip all Agent collection and output on Express.
IF @Engine<>4
BEGIN
-- 03 Agent history: include failures even if subsequently retried successfully.
BEGIN TRY
 EXEC sp_executesql N'
 INSERT #Daily
 SELECT @u,@s,j.name,''Agent failed execution'',''ATTENTION'',
 CONCAT(''Start='',CONVERT(varchar(30),msdb.dbo.agent_datetime(h.run_date,h.run_time),126),
 ''; outcome='',h.run_status,''; '',h.message COLLATE DATABASE_DEFAULT),''msdb.sysjobhistory; job outcome rows''
 FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobhistory h ON h.job_id=j.job_id
 WHERE h.step_id=0 AND h.run_status IN(0,3) AND h.run_date>0
 AND msdb.dbo.agent_datetime(h.run_date,h.run_time)>=@since;
 IF @@ROWCOUNT=0 INSERT #Daily VALUES(@u,@s,@s,''Agent failed execution'',''REVIEW'',
 ''No failed/cancelled outcomes in visible retained history; confirm history retention and job visibility.'',NULL);
 ;WITH ok AS(SELECT job_id, MAX(msdb.dbo.agent_datetime(run_date,run_time)) LastOK
 FROM msdb.dbo.sysjobhistory WHERE step_id=0 AND run_status=1 AND run_date>0 GROUP BY job_id)
 INSERT #Daily SELECT @u,@s,p.JobName,''Agent expected run'',
 CASE WHEN j.job_id IS NULL OR j.enabled=0 OR ok.LastOK IS NULL
 OR ok.LastOK<DATEADD(hour,-p.MaxSuccessAgeHours,@n) THEN ''ATTENTION'' ELSE ''PASS'' END,
 CONCAT(''Enabled='',j.enabled,''; last success='',COALESCE(CONVERT(varchar(30),ok.LastOK,126),''none visible'')),
 ''Explicit #JobPolicy compared with local successful job outcomes''
 FROM #JobPolicy p LEFT JOIN msdb.dbo.sysjobs j
 ON j.name COLLATE DATABASE_DEFAULT=p.JobName COLLATE DATABASE_DEFAULT
 LEFT JOIN ok ON ok.job_id=j.job_id;
 IF NOT EXISTS(SELECT 1 FROM #JobPolicy) INSERT #Daily VALUES(@u,@s,@s,''Agent expected run'',''NOT CHECKED'',
 ''No job policy supplied; missed schedules are not checked.'',NULL);
 INSERT #Daily SELECT @u,@s,j.name,''Agent running job'',
 CASE WHEN p.JobName IS NULL THEN ''REVIEW''
 WHEN DATEDIFF(minute,a.start_execution_date,@n)>p.MaxRunningMinutes THEN ''ATTENTION'' ELSE ''INFO'' END,
 CONCAT(''Started='',CONVERT(varchar(30),a.start_execution_date,126),''; elapsed minutes='',DATEDIFF(minute,a.start_execution_date,@n)),
 ''Latest Agent session; compare approved duration''
 FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON a.job_id=j.job_id
 LEFT JOIN #JobPolicy p ON p.JobName COLLATE DATABASE_DEFAULT=j.name COLLATE DATABASE_DEFAULT
 WHERE a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)
 AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL;
 ',N'@u datetime2,@s nvarchar(256),@since datetime,@n datetime',@Utc,@Server,@Since,@Now;
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Agent coverage','REVIEW',
 'Confirm account sees all jobs and Agent is running; restricted msdb roles may silently hide jobs.',NULL);
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Agent checks','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;

-- 03b SQL Agent service state (instances only; not applicable on Managed Instance).
IF @Engine=8
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Agent service','N/A','Managed Instance Agent service is platform-managed.',NULL);
ELSE BEGIN
 BEGIN TRY
 IF @CanMonitor=0 RAISERROR('Server monitoring permission missing; service state not visible.',16,1);
 EXEC sp_executesql N'
 INSERT #Daily SELECT @u,@s,servicename COLLATE DATABASE_DEFAULT,''Agent service'',
 CASE WHEN status_desc=''Running'' THEN ''PASS'' ELSE ''ATTENTION'' END,
 CONCAT(''Status='',status_desc COLLATE DATABASE_DEFAULT,''; startup='',startup_type_desc COLLATE DATABASE_DEFAULT),
 ''sys.dm_server_services; Agent only''
 FROM sys.dm_server_services WHERE servicename LIKE N''SQL Server Agent%'';
 IF @@ROWCOUNT=0 INSERT #Daily VALUES(@u,@s,@s,''Agent service'',''REVIEW'',
 ''No SQL Server Agent service row visible (Linux or permissions). Confirm Agent is expected.'',NULL);',
 N'@u datetime2,@s nvarchar(256)',@Utc,@Server;
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Agent service','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;
END;

END; -- Express Agent exclusion

-- 04 Host volumes: only volumes containing SQL database files.
IF @Engine=8
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Host volumes','N/A','Managed Instance host disks are managed by Azure; check Azure storage metrics.',NULL);
ELSE BEGIN
 BEGIN TRY
 EXEC sp_executesql N'
 ;WITH v AS(SELECT DISTINCT volume_mount_point,total_bytes,available_bytes
 FROM sys.master_files f CROSS APPLY sys.dm_os_volume_stats(f.database_id,f.file_id))
 INSERT #Daily SELECT @u,@s,COALESCE(volume_mount_point,''unknown volume''),''Host volume space'',
 CASE WHEN total_bytes IS NULL OR available_bytes IS NULL THEN ''NOT CHECKED''
 WHEN 100.0*available_bytes/NULLIF(total_bytes,0)<@crit THEN ''CRITICAL''
 WHEN 100.0*available_bytes/NULLIF(total_bytes,0)<@warn THEN ''ATTENTION'' ELSE ''PASS'' END,
 CONCAT(''Free GB='',CAST(available_bytes/1073741824.0 AS decimal(18,2)),
 ''; free percent='',CAST(100.0*available_bytes/NULLIF(total_bytes,0) AS decimal(8,2))),
 ''sys.dm_os_volume_stats; only database-file volumes; sample thresholds'' FROM v;',
 N'@u datetime2,@s nvarchar(256),@crit decimal(5,2),@warn decimal(5,2)',@Utc,@Server,@DiskCriticalPct,@DiskWarningPct;
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Host volume space','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;
END;

-- Per-database file and log space; offline/inaccessible DBs explicitly surfaced.
DECLARE @db sysname,@sql nvarchar(max);
DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR SELECT d.name FROM sys.databases d
 WHERE d.database_id>4 AND d.name<>@MaintenanceDatabase
 AND NOT EXISTS(SELECT 1 FROM #OmittedDatabases x WHERE x.DatabaseName=d.name COLLATE DATABASE_DEFAULT);
OPEN dbs; FETCH NEXT FROM dbs INTO @db;
WHILE @@FETCH_STATUS=0 BEGIN
 BEGIN TRY
 SET @sql=N'USE '+QUOTENAME(@db)+N';
 INSERT #Daily SELECT @u,@s,DB_NAME()+''/''+name,''Data file space'',
 CASE WHEN FILEPROPERTY(name,''SpaceUsed'') IS NULL THEN ''NOT CHECKED''
 WHEN 100.0*FILEPROPERTY(name,''SpaceUsed'')/NULLIF(size,0)>=@warn THEN ''REVIEW'' ELSE ''INFO'' END,
 CONCAT(''Allocated MB='',CAST(size/128.0 AS decimal(18,2)),
 ''; used MB='',CAST(FILEPROPERTY(name,''SpaceUsed'')/128.0 AS decimal(18,2)),
 ''; max_size pages='',max_size,''; growth='',growth,''; percent_growth='',is_percent_growth),
 ''sys.database_files; high file occupancy alone is not a disk-capacity failure''
 FROM sys.database_files WHERE type=0;
 INSERT #Daily SELECT @u,@s,DB_NAME(),''Log space'',
 CASE WHEN used_log_space_in_percent>=@warn THEN ''REVIEW'' ELSE ''INFO'' END,
 CONCAT(''Log MB='',CAST(total_log_size_in_bytes/1048576.0 AS decimal(18,2)),
 ''; used percent='',CAST(used_log_space_in_percent AS decimal(8,2)),
 ''; reuse wait='',(SELECT log_reuse_wait_desc FROM sys.databases WHERE database_id=DB_ID())),
 ''sys.dm_db_log_space_usage; current snapshot; investigate in workload context''
 FROM sys.dm_db_log_space_usage;';
 EXEC sp_executesql @sql,N'@u datetime2,@s nvarchar(256),@warn decimal(5,2)',@Utc,@Server,@FileUsedWarningPct;
 END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@db,'Database space','NOT CHECKED',ERROR_MESSAGE(),NULL);
 END CATCH;
 FETCH NEXT FROM dbs INTO @db;
END;
CLOSE dbs; DEALLOCATE dbs;

-- 05 AGs. On primary you see remote states; on secondary visibility is local.
IF @Engine=8
 INSERT #Daily VALUES(@Utc,@Server,@Server,'AG health','N/A','Use Azure failover-group monitoring for MI; internal managed HA is not a user-managed AG.',NULL);
ELSE IF @IsHadrEnabled=0
 INSERT #Daily VALUES(@Utc,@Server,@Server,'AG health','N/A',
 'Availability Groups feature is disabled on this instance. The other daily checks still run.',
 'SERVERPROPERTY(IsHadrEnabled)=0; does not assess other HA/DR technologies');
ELSE IF @IsHadrEnabled IS NULL
 INSERT #Daily VALUES(@Utc,@Server,@Server,'AG health','NOT CHECKED',
 'Could not determine whether Availability Groups are enabled.',
 'SERVERPROPERTY(IsHadrEnabled) returned NULL');
ELSE BEGIN
 BEGIN TRY
 IF @CanMonitor=0 RAISERROR('Server monitoring permission missing; AG results could be incomplete.',16,1);
 IF NOT EXISTS(SELECT 1 FROM sys.availability_groups)
  INSERT #Daily VALUES(@Utc,@Server,@Server,'AG health','REVIEW',
  'AG feature is enabled, but no AG is visible on this instance. Confirm expected topology and metadata permissions.',
  'SERVERPROPERTY(IsHadrEnabled)=1; sys.availability_groups has no visible rows');
 ELSE EXEC sp_executesql N'
 INSERT #Daily SELECT @u,@s,ar.replica_server_name,''AG replica'',
 CASE WHEN rs.connected_state_desc=''DISCONNECTED'' OR rs.synchronization_health_desc<>''HEALTHY''
 THEN ''ATTENTION'' ELSE ''INFO'' END,
 CONCAT(''Role='',rs.role_desc COLLATE DATABASE_DEFAULT,
 ''; connection='',rs.connected_state_desc COLLATE DATABASE_DEFAULT,
 ''; health='',rs.synchronization_health_desc COLLATE DATABASE_DEFAULT,
 ''; mode='',ar.availability_mode_desc COLLATE DATABASE_DEFAULT),
 ''Replica state visible from the current node''
 FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_replicas ar ON ar.replica_id=rs.replica_id;
 INSERT #Daily SELECT @u,@s,CONCAT(ar.replica_server_name COLLATE DATABASE_DEFAULT,
 ''/'',adc.database_name COLLATE DATABASE_DEFAULT),''AG database'',
 CASE WHEN d.is_suspended=1 OR d.synchronization_health_desc<>''HEALTHY'' THEN ''ATTENTION''
 WHEN COALESCE(d.log_send_queue_size,0)>@q*1024.0 OR COALESCE(d.redo_queue_size,0)>@q*1024.0 THEN ''REVIEW'' ELSE ''INFO'' END,
 CONCAT(''State='',d.synchronization_state_desc COLLATE DATABASE_DEFAULT,
 ''; health='',d.synchronization_health_desc COLLATE DATABASE_DEFAULT,
 ''; suspended='',d.is_suspended,''; send KB='',d.log_send_queue_size,''; redo KB='',d.redo_queue_size,
 ''; failover_ready='',cs.is_failover_ready,''; mode='',ar.availability_mode_desc COLLATE DATABASE_DEFAULT),
 ''Snapshot; queue thresholds are examples, not an RPO/RTO calculation''
 FROM sys.dm_hadr_database_replica_states d
 JOIN sys.availability_databases_cluster adc ON adc.group_database_id=d.group_database_id
 JOIN sys.availability_replicas ar ON ar.replica_id=d.replica_id
 LEFT JOIN sys.dm_hadr_database_replica_cluster_states cs ON cs.replica_id=d.replica_id AND cs.group_database_id=d.group_database_id
 WHERE adc.database_name COLLATE DATABASE_DEFAULT<>@m COLLATE DATABASE_DEFAULT
 AND NOT EXISTS(SELECT 1 FROM #OmittedDatabases x WHERE x.DatabaseName=adc.database_name COLLATE DATABASE_DEFAULT);',
 N'@u datetime2,@s nvarchar(256),@q int,@m sysname',@Utc,@Server,@QueueWarningMB,@MaintenanceDatabase;
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'AG health','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;
END;

-- 06 Current blocking and long-running requests: do not equate elapsed time with blocking time.
BEGIN TRY
 IF @CanMonitor=0 RAISERROR('Server monitoring permission missing; request visibility could be limited to this session.',16,1);
 EXEC sp_executesql N'
 INSERT #Daily SELECT @u,@s,CONCAT(''session '',r.session_id),''Current blocked request'',
 CASE WHEN r.wait_time>=@sec*1000.0 THEN ''ATTENTION'' ELSE ''REVIEW'' END,
 CONCAT(''DB='',DB_NAME(r.database_id) COLLATE DATABASE_DEFAULT,''; blocker='',r.blocking_session_id,
 ''; current wait='',r.wait_type COLLATE DATABASE_DEFAULT,''; wait ms='',r.wait_time,''; elapsed ms='',r.total_elapsed_time),
 ''sys.dm_exec_requests; negative blocker IDs have special meanings; no SQL text collected''
 FROM sys.dm_exec_requests r WHERE r.blocking_session_id<>0 AND r.session_id<>@@SPID;
 IF @@ROWCOUNT=0 INSERT #Daily VALUES(@u,@s,@s,''Current blocking'',''PASS'',
 ''No blocked requests visible at sample time; does not cover the prior 24 hours.'',NULL);
 INSERT #Daily SELECT @u,@s,CONCAT(''session '',r.session_id),''Long request'',''REVIEW'',
 CONCAT(''DB='',DB_NAME(r.database_id) COLLATE DATABASE_DEFAULT,
 ''; command='',r.command COLLATE DATABASE_DEFAULT,''; elapsed ms='',r.total_elapsed_time),
 ''Current user request over 5 minutes; duration may be expected''
 FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id=r.session_id
 WHERE s.is_user_process=1 AND r.session_id<>@@SPID AND r.total_elapsed_time>300000;
 INSERT #Daily SELECT @u,@s,@s,''SQL process memory'',
 CASE WHEN process_physical_memory_low=1 OR process_virtual_memory_low=1 THEN ''ATTENTION'' ELSE ''INFO'' END,
 CONCAT(''Physical low='',process_physical_memory_low,''; virtual low='',process_virtual_memory_low,
 ''; physical used MB='',physical_memory_in_use_kb/1024),''Current process memory flags; not full resource history''
 FROM sys.dm_os_process_memory;',N'@u datetime2,@s nvarchar(256),@sec int',@Utc,@Server,@BlockingSeconds;
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Current workload and memory','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;

-- 07 Deadlocks: opt-in full retained-file scan. Time filter does NOT avoid reading old files.
IF @ReadDeadlockFiles=0
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Deadlock history','NOT CHECKED',
 'XE scan disabled. Review retained Redgate/XE history separately or enable after assessing file volume.',NULL);
ELSE BEGIN
 BEGIN TRY
 IF @XePattern IS NULL BEGIN
  DECLARE @Target xml,@CurrentFile nvarchar(4000);
  SELECT @Target=CONVERT(xml,t.target_data) FROM sys.dm_xe_session_targets t
  JOIN sys.dm_xe_sessions s ON s.address=t.event_session_address
  WHERE s.name='system_health' AND t.target_name='event_file';
  SET @CurrentFile=@Target.value('(EventFileTarget/File/@name)[1]','nvarchar(4000)');
  IF @CurrentFile IS NOT NULL AND @CurrentFile NOT LIKE 'https://%' BEGIN
   DECLARE @Backslash int=CHARINDEX('\',REVERSE(@CurrentFile)),
           @Slash int=CHARINDEX('/',REVERSE(@CurrentFile)),@Separator int;
   SET @Separator=CASE WHEN @Backslash=0 THEN @Slash WHEN @Slash=0 THEN @Backslash
    WHEN @Backslash<@Slash THEN @Backslash ELSE @Slash END;
   IF @Separator>0 SET @XePattern=LEFT(@CurrentFile,LEN(@CurrentFile)-@Separator+1)+N'system_health*.xel';
  END;
 END;
 IF @XePattern IS NULL RAISERROR('No local event-file path discovered. Supply an authorised explicit XE pattern for MI/blob targets.',16,1);
 IF OBJECT_ID('tempdb..#XE') IS NOT NULL DROP TABLE #XE;
 SELECT object_name, TRY_CONVERT(xml,event_data) EventXml INTO #XE
 FROM sys.fn_xe_file_target_read_file(@XePattern,NULL,NULL,NULL);
 DECLARE @Oldest datetime2,@Newest datetime2,@Deadlocks int;
 SELECT @Oldest=MIN(EventXml.value('(event/@timestamp)[1]','datetime2')),
 @Newest=MAX(EventXml.value('(event/@timestamp)[1]','datetime2')) FROM #XE;
 SELECT @Deadlocks=COUNT(*) FROM #XE WHERE object_name='xml_deadlock_report'
 AND EventXml.value('(event/@timestamp)[1]','datetime2')>=@SinceUtc
 AND EventXml.value('(event/@timestamp)[1]','datetime2')<=@Utc;
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Deadlock history',
 CASE WHEN @Deadlocks>0 THEN 'ATTENTION' ELSE 'REVIEW' END,
 CONCAT('Deadlocks in UTC window=',@Deadlocks,'; retained oldest UTC=',CONVERT(varchar(30),@Oldest,126),
 '; retained newest UTC=',CONVERT(varchar(30),@Newest,126)),
 'Retained-file count only; verify continuous collection/retention before claiming zero deadlocks');
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Deadlock history','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;
END;

-- 08 Ola CommandLog: grouped errors; incomplete commands summarised separately.
BEGIN TRY
 IF DB_ID(@MaintenanceDatabase) IS NULL RAISERROR('Configured maintenance database not visible or absent.',16,1);
 SET @sql=N'USE '+QUOTENAME(@MaintenanceDatabase)+N';
 IF OBJECT_ID(N''dbo.CommandLog'',N''U'') IS NULL RAISERROR(''dbo.CommandLog not found.'',16,1);
 DECLARE @total bigint,@errors bigint,@incomplete bigint;
 SELECT @total=COUNT_BIG(*),
 @errors=COALESCE(SUM(CONVERT(bigint,CASE WHEN COALESCE(c.ErrorNumber,0)<>0 THEN 1 ELSE 0 END)),0),
 @incomplete=COALESCE(SUM(CONVERT(bigint,CASE WHEN c.EndTime IS NULL AND COALESCE(c.ErrorNumber,0)=0 THEN 1 ELSE 0 END)),0)
 FROM dbo.CommandLog c
 WHERE c.StartTime>=@since AND c.StartTime<=@now
 AND EXISTS(SELECT 1 FROM sys.databases d WHERE d.database_id>4 AND d.name<>@m
            AND d.name COLLATE DATABASE_DEFAULT=c.DatabaseName COLLATE DATABASE_DEFAULT
            AND NOT EXISTS(SELECT 1 FROM #OmittedDatabases x WHERE x.DatabaseName=d.name COLLATE DATABASE_DEFAULT));
 INSERT INTO #Daily(CheckTimeUtc,ServerName,Resource,CheckName,Status,Finding,Evidence)
 SELECT @u,@s,c.DatabaseName,''Maintenance errors'',''ATTENTION'',
 CONCAT(''Type='',c.CommandType COLLATE DATABASE_DEFAULT,''; error='',c.ErrorNumber,''; failed commands='',COUNT_BIG(*)),
 CONCAT(''First start='',CONVERT(varchar(30),MIN(c.StartTime),126),
 ''; last start='',CONVERT(varchar(30),MAX(c.StartTime),126),
 ''; sample error message='',MAX(c.ErrorMessage COLLATE DATABASE_DEFAULT),
 ''; grouped by database, command type and error number; inspect CommandLog on this instance for all affected objects'')
 FROM dbo.CommandLog c
 WHERE c.StartTime>=@since AND c.StartTime<=@now AND COALESCE(c.ErrorNumber,0)<>0
 AND EXISTS(SELECT 1 FROM sys.databases d WHERE d.database_id>4 AND d.name<>@m
            AND d.name COLLATE DATABASE_DEFAULT=c.DatabaseName COLLATE DATABASE_DEFAULT
            AND NOT EXISTS(SELECT 1 FROM #OmittedDatabases x WHERE x.DatabaseName=d.name COLLATE DATABASE_DEFAULT))
 GROUP BY c.DatabaseName,c.CommandType,c.ErrorNumber;
 IF @incomplete>0
 INSERT INTO #Daily(CheckTimeUtc,ServerName,Resource,CheckName,Status,Finding,Evidence)
 VALUES(@u,@s,@s,''Maintenance incomplete'',''REVIEW'',
 CONCAT(@incomplete,'' commands have no EndTime and no recorded error; may be running or interrupted.''),
 ''One instance summary for in-scope user databases; inspect CommandLog and Agent jobs before classifying these as failures.'');
 IF @errors=0 AND @incomplete=0
 INSERT INTO #Daily(CheckTimeUtc,ServerName,Resource,CheckName,Status,Finding,Evidence)
 VALUES(@u,@s,@s,''Maintenance outcomes'',CASE WHEN @total=0 THEN ''REVIEW'' ELSE ''PASS'' END,
 CASE WHEN @total=0 THEN N''No CommandLog entries for in-scope user databases within window. Confirm schedule and retention.''
 ELSE CONCAT(@total,N'' in-scope user database commands in window; no recorded errors or incomplete commands.'') END,
 N''dbo.CommandLog; recorded outcomes only, not proof that every expected database was covered'');';
 EXEC sp_executesql @sql,N'@u datetime2,@s nvarchar(256),@since datetime,@now datetime,@m sysname',
 @Utc,@Server,@Since,@Now,@MaintenanceDatabase;
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Integrity coverage','REVIEW',
 'Compare successful DBCC_CHECKDB commands with the expected in-scope user database schedule; the Last good CHECKDB rows above are the direct check.',NULL);
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Maintenance outcomes','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;

-- Optional error-log triage. Bounded archive count; keyword matches are candidates.
IF @ReadErrorLogs=0
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Error log history','NOT CHECKED','Error-log scan disabled; review in monitoring or enable here.',NULL);
ELSE BEGIN
 BEGIN TRY
 IF @ErrorLogArchives<0 OR @ErrorLogArchives>20 RAISERROR('ErrorLogArchives must be 0 to 20.',16,1);
 IF OBJECT_ID('tempdb..#ErrorLogs') IS NOT NULL DROP TABLE #ErrorLogs;
 CREATE TABLE #ErrorLogs(LogDate datetime, ProcessInfo nvarchar(50), LogText nvarchar(max));
 DECLARE @Archive int=0;
 WHILE @Archive<=@ErrorLogArchives BEGIN
  BEGIN TRY
   INSERT #ErrorLogs EXEC master.dbo.xp_readerrorlog @Archive,1,NULL,NULL,@Since,@Now,N'asc';
  END TRY BEGIN CATCH
   INSERT #Daily VALUES(@Utc,@Server,@Server,'Error log archive','NOT CHECKED',CONCAT('Archive ',@Archive,': ',ERROR_MESSAGE()),NULL);
  END CATCH;
  SET @Archive=@Archive+1;
 END;
 INSERT #Daily SELECT @Utc,@Server,@Server,'Login failures',CASE WHEN COUNT(*)>0 THEN 'REVIEW' ELSE 'INFO' END,
 CONCAT(COUNT(*),' failed-login messages in the scanned window; user names and client addresses are not reproduced here.'),
 'xp_readerrorlog; count of lines starting Login failed for user' FROM #ErrorLogs WHERE LogText LIKE 'Login failed for user%';
 INSERT #Daily SELECT @Utc,@Server,@Server,'Error log candidate','REVIEW',
 CONCAT(CONVERT(varchar(30),LogDate,126),' ',ProcessInfo,' ',LogText),
 'Server-local timestamp; keyword triage only; retain surrounding log context'
 FROM #ErrorLogs WHERE (LogText LIKE '%Error:%' OR LogText LIKE '%Severity:%'
 OR LogText LIKE '%I/O requests taking longer%' OR LogText LIKE '%stack dump%'
 OR LogText LIKE '%fail%' OR LogText LIKE '%corrupt%')
 AND LogText NOT LIKE 'Login failed for user%' AND LogText NOT LIKE 'Error: 18456,%';
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Error log coverage','REVIEW',
 CONCAT(N'Scanned available archives 0 to ',@ErrorLogArchives,N'. Rotation/deletion, keyword coverage and server-local clock can leave gaps.'),NULL);
END TRY BEGIN CATCH
 INSERT #Daily VALUES(@Utc,@Server,@Server,'Error log history','NOT CHECKED',ERROR_MESSAGE(),NULL);
END CATCH;
END;
INSERT #Daily VALUES(@Utc,@Server,@Server,'Restore validation','NOT CHECKED',
 'Restore tests run in the test environment. Review the latest test evidence separately; this production script does not execute restores.',NULL);
INSERT #Daily VALUES(@Utc,@Server,@Server,'External checks','NOT CHECKED',
 'Review retained alerts, security alerts and DR/failover policy separately. Not collected by this script.',NULL);
-- SET LOCK_TIMEOUT requires a numeric literal. Build it before executing.
-- The default (-1) is restored with a literal so it takes effect in this session; verify with SELECT @@LOCK_TIMEOUT.
IF @OldLockTimeout=-1 SET LOCK_TIMEOUT -1;
ELSE BEGIN
 DECLARE @RestoreLockTimeoutSql nvarchar(50);
 SET @RestoreLockTimeoutSql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @OldLockTimeout);
 EXEC sys.sp_executesql @RestoreLockTimeoutSql;
END;
SELECT CheckTimeUtc,ServerName,Resource,CheckName,Status,Finding,Evidence,
 CAST(NULL AS nvarchar(100)) Ticket,CAST(NULL AS nvarchar(100)) Owner,
 CAST(NULL AS nvarchar(100)) NextUpdate FROM #Daily
WHERE @ExceptionsOnly=0 OR Status IN ('CRITICAL','ATTENTION','REVIEW','NOT CHECKED')
ORDER BY CASE Status WHEN 'CRITICAL' THEN 1 WHEN 'ATTENTION' THEN 2 WHEN 'NOT CHECKED' THEN 3 WHEN 'REVIEW' THEN 4 ELSE 5 END,CheckName,Resource;
