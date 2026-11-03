# SQL Server 2019: RCSI and ADR implementation pack

Revised 2 November 2026. Scope: one user database on one SQL Server 2019 instance.
Snapshot Isolation (SI) deployment is excluded. No script changes ALLOW_SNAPSHOT_ISOLATION or sets a session to SNAPSHOT. Existing SI configuration is reported for operational awareness because it can affect version retention and capacity.

## Files

| File | Purpose |
|---|---|
| 01_Prechecks.sql | Read-only current settings, build, connections, transactions, capacity, backups and hint-review candidates. |
| 02_Enable_RCSI.sql | Preview/enable statement-level versioned READ COMMITTED reads. |
| 03_Enable_ADR.sql | Preview/enable accelerated recovery, using default PRIMARY PVS placement. |
| 04_Monitor.sql | Read-only version-store, transactions, requests, storage and local AG queue checks. |
| 05_Reverse_One_Feature.sql | Preview/reverse RCSI or ADR individually, based on the original baseline. |

## Before implementation

1. Use a dedicated SSMS connection on one instance, running as an authorised sysadmin. Do not use Registered Servers/multi-server execution or concatenate the files. Scripts intentionally require sysadmin for complete visibility; they do not grant permissions.
2. Obtain the exact instance identifier with `SELECT SERVERPROPERTY('ServerName');`. Set @ExpectedServer and @DatabaseName in every file.
3. Run 01 and save all results as the pre-change baseline. Confirm backups and a tested restore process; backup-history rows alone do not prove recoverability. For AGs, inspect backup history on other backup replicas too.
4. Confirm vendor/application support and review the exact SQL Server 2019 build and applicable fixes. Review CDC, replication, mirroring, memory-optimised tables, FILESTREAM, HA/DR, cross-database access, explicit isolation levels and hints. Automated checks do not certify full compatibility.
5. ADR and CDC together are unsupported in a SQL Server 2019 database. ADR is also unsupported with database mirroring. ADR enablement refuses these configurations. Replication and other log consumers require separate review of log-retention implications.
6. Test a representative restored copy in an isolated environment. Cover concurrent reporting and writes, imports, queue processing (especially READPAST), batches, and read/decide/update business logic. Existing NOLOCK queries do not become safe committed reads just because RCSI is enabled.
7. Size tempdb for RCSI before ADR, then size the user database for ADR/PVS. PRIMARY is the default PVS location used here. A dedicated PVS filegroup or relocation requires a separate reviewed storage plan.

## Three-week sequence

- Week 1: prechecks, representative workload baseline, application/vendor review, test environment and agreed acceptance criteria.
- Week 2: test RCSI alone, then ADR with RCSI; measure response time, blocking, version-store growth and cleanup. Perform controlled rollback/recovery tests only in the approved isolated environment. Rehearse deployment and reversal.
- Week 3: deploy RCSI in its approved window; observe a representative business cycle. Deploy ADR separately only after RCSI is stable, then monitor and hand over. Extend observation if the workload cycle is longer. Record month-end validation as outstanding if not covered.

## Each change window

1. Preview ONE enable file with @ExecuteChange = 0.
2. Drain the target: stop new application/pool connections, relevant Agent/ETL/reporting jobs and monitoring access. Let transactions finish. Close other SSMS/Object Explorer connections to the target. Keep reconnects stopped until the change completes.
3. Run from master on the current primary for an AG database. The scripts refuse changes while target sessions, requests or database transactions remain, including transactions held by sessions in another database context. They never kill sessions, force rollback or change database user-access mode.
4. Set @ExecuteChange = 1 and run the complete selected file. WITH NO_WAIT fails instead of waiting for required access; it does not prevent racing reconnects. LOCK_TIMEOUT limits lock waits, not total execution duration.
5. Verify returned flags, restore application access, perform business smoke tests and run 04. Record UTC change times. Do not introduce ADR until RCSI observation and correctness checks pass.

## Monitoring and acceptance

04 returns point-in-time data, not historical storage or automated alerts. Save timestamped samples through existing monitoring. Use Query Store, Extended Events and application telemetry for matched-workload performance, deadlocks, timeouts and user impact.

Monitor target traditional tempdb version-store allocation before ADR; after ADR, monitor user-database PVS, disk/file headroom, retained versions, cleanup trends, CPU/I/O, transaction log and AG queues where relevant. Long-running versioning readers and existing SNAPSHOT transactions can retain versions.

PVS reported MB measures OFF-ROW allocation and excludes in-row versions. No row/zero does not prove there is no version-related storage. tempdb still needs space for other databases and operations after enabling ADR here.

Require correct business results, acceptable response times and throughput, reduced targeted reader-writer blocking, no unexplained timeouts, sustainable storage/cleanup and a measured ADR recovery/rollback benefit in test. Set workload-specific alert and reversal thresholds before production. RCSI does not eliminate writer-writer or schema-lock blocking or all deadlocks. ADR does not replace backups or HA/DR.

## Reversal

Use 05 for ONE feature per execution, only if the saved baseline proves that feature was OFF before this rollout. Existing features are not automatically reset. SI is never changed.

Set @Feature to RCSI or ADR, @BaselineWasOff = 1, preview, then set @ExecuteChange = 1 in the approved drained window. Reverse in dependency-aware order, normally ADR then RCSI if both were newly introduced. Disabling ADR while RCSI or pre-existing SI remains enabled moves new isolation versions to tempdb: confirm its headroom first.

Investigate PVS retention/cleanup before disabling ADR to manage storage pressure. ADR OFF does not instantly reclaim PVS space. No shrink, forced cleanup or KILL is included. After failure/cancellation, inspect actual state before retrying and verify application health after reversal.

## Validation limits

Files were statically reviewed and ZIP integrity checked. They have not been executed against SQL Server in this environment. Rehearsal on the exact SQL Server 2019 build and application remains required.

## Microsoft references

- https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-set-options?view=sql-server-ver15
- https://learn.microsoft.com/en-us/sql/relational-databases/accelerated-database-recovery-management?view=sql-server-ver15
- https://learn.microsoft.com/en-us/sql/relational-databases/accelerated-database-recovery-troubleshoot?view=sql-server-ver15
- https://learn.microsoft.com/en-us/sql/relational-databases/track-changes/known-issues-and-errors-change-data-capture?view=sql-server-ver15

## Query Store, deadlocks and blocking (added)

SI deployment remains excluded. These additions do not change its settings.

| File | Purpose |
|---|---|
| 06_Enable_Query_Store.sql | Query Store READ_WRITE, AUTO capture, waits ON, 15-minute intervals, 30-day cleanup and a configurable 1 GB limit. |
| 07_Enable_Deadlock_Blocking_Capture.sql | Dedicated server XE session plus explicit opt-in to a 15-second instance blocked-process threshold if currently OFF. |
| 08_Query_Store_Report.sql | Query performance and aggregated Lock waits for the target database. |
| 09_Read_Deadlocks_Blocks.sql | Historical deadlock graphs and blocking reports filtered to the target database. |

Deploy these monitoring features in Week 1, BEFORE RCSI/ADR, to collect baseline evidence. Query Store does not record deadlock graphs or blocking chains. The XE session captures all databases to preserve complete cross-database graphs, while 09 filters the output. Existing system_health already captures deadlocks; this separate session supplies dedicated rollover retention plus blocking reports.

Run 06 in preview, save its original options, then execute. It preserves existing enabled Query Store settings unless @AllowReconfigureExisting=1. If already enabled, review the returned state/wait-capture settings first. AUTO may omit infrequent queries; capture is not an audit of every execution. Storage cleanup can shorten retention, and Query Store can become READ_ONLY. Monitor actual_state_desc, readonly_reason and size. A 1 GB limit is a starting point, not a workload sizing guarantee. No plans are forced and no existing history is cleared.

For 07 set @XelFilename to a dedicated .xel file on an existing server directory. The SQL Server service account needs write access. Change 09 to the matching filename prefix with *.xel. A separate name/path is required on each possible AG primary because XE sessions and server settings are not AG database objects. Readers on SQL Server 2019 secondaries are outside this Query Store capture scope; collect their diagnostics separately as needed.

07 defaults to @ExecuteChange=0. If the existing blocked-process threshold is zero, set @EnableInstanceBlockingReports=1 to authorise enabling it at 15 seconds across the INSTANCE. Nonzero effective thresholds are preserved. Values 1-4 are refused for separate correction. The script refuses unrelated pending configuration changes before RECONFIGURE. Save the original threshold and show-advanced-options state. Its original show-advanced-options state is restored on the successful path; inspect configuration manually after any partial error.

The XE target uses 50 MB files and 8 rollover files. Check available volume space and observe actual retention; archive if longer history is required. ALLOW_SINGLE_EVENT_LOSS makes capture best effort. Rollover and overload can lose evidence. Blocking reports are periodic eligible long lock waits, not every wait; repeated reports can refer to one blocking episode. They are not a unique incident count. Query Store Lock wait aggregates identify affected queries but do not name their blockers. Read 09 for the graph/chain and use 04 for live requests.

Validate Query Store READ_WRITE, the XE session RUNNING and effective blocked-process threshold. Validate actual capture with controlled concurrent-session tests in the isolated test database. No artificial deadlock/blocking is generated in production by these scripts. Check file permissions, path, rollover and XML results. Static checks here do not replace server execution tests.

### Monitoring reversal (separate from 05)

05 only reverses RCSI/ADR. For the monitoring additions, first save baseline options and establish ownership:

- Stop the exact new XE session with ALTER EVENT SESSION [the_recorded_session_name] ON SERVER STATE=STOP, then DROP EVENT SESSION [the_recorded_session_name] ON SERVER only if it belongs to this change. Retain the .xel files as evidence; removal of the session does not remove the files.
- Restore the blocked-process threshold only if THIS change altered it and no other monitoring now depends on it. Use the recorded previous value and the usual reviewed sp_configure/RECONFIGURE procedure, including pending-configuration checks and restoration of show advanced options. Stopping XE alone does not revert the threshold.
- If Query Store was previously OFF, ALTER DATABASE [the_verified_database] SET QUERY_STORE = OFF stops collection and retains stored data on SQL Server 2019. Do not run QUERY_STORE CLEAR. If it was already enabled, restore the recorded previous options rather than disabling it. Confirm actual state afterwards.

Additional Microsoft references:

- https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store
- https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/understand-resolve-blocking
- https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/blocked-process-threshold-server-configuration-option
- https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-deadlocks-guide
