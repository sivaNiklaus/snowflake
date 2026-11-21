# Snowflake SQL deployment

## Phase 3: raw ingestion task graph

The task graph reuses the already-deployed external stages, named file formats,
raw tables, and the `COPY INTO` logic in the existing ingestion scripts. It
does not recreate or modify those objects. Phase 2 pipe definitions and DCM
definitions remain untouched.

| Feed | Stage | File format | Target |
| --- | --- | --- | --- |
| Members | `SKYPOINTS_DB.RAW.MEMBER_S3_STAGE` | `SKYPOINTS_DB.RAW.MEMBER_PROFILE_CSV` | `SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW` |
| Redemptions | `SKYPOINTS_DB.RAW.REDEMPTION_S3_STAGE` | `SKYPOINTS_DB.RAW.REDEMPTION_JSON` | `SKYPOINTS_DB.RAW.REDEMPTION_RAW` |

`sql/orchestration/deploy_ingestion_task_graph.sql` creates the audit table,
three SQL stored procedures, and three Snowflake tasks. Only the audit table,
procedures, and tasks are managed by this script; database, schemas, warehouse,
stages, formats, and raw tables remain the responsibility of the existing
deployment. The procedures use the same projections as the standalone COPY
scripts:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/deploy_ingestion_task_graph.sql
```

Run deployment with a role that can create procedures and tasks in
`SKYPOINTS_DB.RAW`, create the audit table in `SKYPOINTS_DB.AUDIT`, use
`SKYPOINTS_ETL_WH`, and own/operate the tasks. The task owner needs `USAGE` on
the warehouse and the global `EXECUTE TASK` privilege. The procedures execute
as their owner, so that role also needs access to the existing stages and raw
tables. Use the same owning role for all tasks in the graph.

The deployment script is rerunnable, resumes the child tasks in dependency
order, and does not define a schedule. The root stays suspended because it has
no schedule; `EXECUTE TASK` triggers it manually.
The graph is:

1. `TASK_MEMBER_INGESTION` is the root and copies the member feed.
2. `TASK_REDEMPTION_INGESTION` runs after successful member ingestion.
3. `TASK_INGESTION_VALIDATION` runs after successful redemption ingestion.

Each task uses `SKYPOINTS_ETL_WH`. The member copy stores `$1::VARCHAR` as
`SOURCE_RECORD`, preserving the full physical source line. The redemption copy
stores `$1::VARIANT` as `PAYLOAD`; neither feed is parsed or flattened.
Both projections include filename, row number, content key, and scan timestamp,
and use `ON_ERROR = 'ABORT_STATEMENT'` without `FORCE = TRUE`. Snowflake's
per-table COPY load history provides file-level de-duplication on reruns.

### Manual execution

After deploying the graph, execute:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/execute_ingestion_task_graph.sql
```

The deployment script resumes the child tasks in dependency order and leaves
the root suspended. The execution script runs the full graph synchronously
using this single trigger:

```sql
EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT;
```

The root has no schedule and runs only when manually triggered. Scheduling is
out of scope. Before running, ensure the existing auto-ingest pipes are not
concurrently consuming the same S3 prefixes.

### Audit, monitoring, and recovery

Every procedure writes a `RUNNING` audit row, then records `SUCCEEDED` or
`FAILED`, start/end timestamps, run ID, loaded row count, source files, and
error details. The validation task records both raw-table row counts and the
member/redemption source-file lists. Critical NULL checks and empty raw tables
fail validation and prevent downstream success. Exceptions are re-raised after
audit updates, so
Snowflake task history also reports the failure. Failures before a procedure
starts (for example, task privilege or warehouse errors) are visible in task
history even if no audit row was started.

For a successful graph run, task history shows all three tasks as
`SUCCEEDED`. The audit table has member and redemption rows with their COPY
row/file results and a validation row with both table counts and source-file
lists. A failed COPY or nonzero critical NULL count produces a `FAILED` task
and an audit error message.

Inspect recent task status and audit records with:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/monitor_ingestion_task_graph.sql
```

The task-history table function covers the preceding seven days; the audit
table retains its records until explicitly managed. If a run fails, inspect
both views, correct the source or permission issue, and manually trigger the
root again. Successful files are skipped by Snowflake's load history; do not
use `FORCE = TRUE`. Republish corrected content under a new S3 object key if
the original key was already loaded.

If the graph definition has not changed and the failed run is within
Snowflake's 14-day retry window, the failed portion can instead be retried:

```sql
EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION RETRY LAST;
```

`RETRY LAST` is not synchronous and does not support `AWAIT`; monitor its
completion with the task-history and audit queries above.

The monitoring role needs task `MONITOR` or `OPERATE` privileges (or global
`MONITOR EXECUTION`) and `USAGE` on the task database and schema.

The standalone manual COPY and validation scripts remain available for
diagnostics, but should not run concurrently with this graph or active pipes:

```powershell
snow sql --connection <connection_name> --filename sql/ingestion/load_member_profile.sql
snow sql --connection <connection_name> --filename sql/ingestion/load_redemption.sql
snow sql --connection <connection_name> --filename sql/ingestion/validate_member_profile.sql
snow sql --connection <connection_name> --filename sql/ingestion/validate_redemption.sql
```

Run local static checks with `python -m pytest`. These tests do not connect to
or deploy against Snowflake. No Snowflake account deployment or execution is
claimed by this repository change.

Task dependencies, suspended-child execution behavior, `EXECUTE TASK ... AWAIT`,
`SYSTEM$TASK_RUNTIME_INFO`, and task history were checked against Snowflake's
[CREATE TASK](https://docs.snowflake.com/en/sql-reference/sql/create-task),
[task graph](https://docs.snowflake.com/en/user-guide/tasks-graphs),
[EXECUTE TASK](https://docs.snowflake.com/en/sql-reference/sql/execute-task),
[SYSTEM$TASK_RUNTIME_INFO](https://docs.snowflake.com/en/sql-reference/functions/system_task_runtime_info),
and [TASK_HISTORY](https://docs.snowflake.com/en/sql-reference/functions/task_history)
documentation.

## Combined Phase 4-5: metadata-driven DQ and business processing

Phase 4-5 adds processing downstream from the existing Phase 3 validation
task. It does not alter raw table definitions, stages, formats, S3 integration,
or ingestion procedures. Run the existing Phase 3 deployment first, then
deploy the new DDL, procedures, and child tasks:

```powershell
snow sql --connection <connection_name> --filename sql/processing/deploy_ingestion_dq_and_business_transformation.sql
```

Use the same deployment role that owns the Phase 3 task graph. It needs create
and operate privileges for procedures/tables/tasks in the existing schemas,
warehouse usage, and the required task execution privileges. The script uses
idempotent table DDL, upserts the known DQ rules, replaces only its processing
procedures/tasks. New tasks are suspended by default; deployment also suspends
the existing Phase 3 descendants, leaving the full chain dormant and
unscheduled. The Phase 3 root remains suspended.

```text
TASK_MEMBER_INGESTION
 -> TASK_REDEMPTION_INGESTION
 -> TASK_INGESTION_VALIDATION
 -> TASK_PARSE_AND_NORMALIZE
 -> TASK_DQ_VALIDATION
 -> TASK_MEMBER_PROCESSING
 -> TASK_REDEMPTION_PROCESSING
```

All tasks use `SKYPOINTS_ETL_WH` and the same owning role. Execute the full
graph only after both deployment scripts have succeeded:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/execute_ingestion_dq_and_business_transformation.sql
```

The execution script resumes descendants in reverse dependency order, manually
starts the original suspended root, waits for all descendants, and suspends
them again after a successful run. Deployment is separate and does not execute
the graph. If execution fails before the final suspend statements, suspend the
descendants manually after reviewing task history.
Monitor runs with:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/monitor_ingestion_dq_and_business_transformation.sql
```

The monitor script includes task history, per-procedure audit, per-dataset DQ
totals, individual rule outcome counts, quarantine totals, and current-member
referential-integrity checks.

### DQ configuration and quarantine

`AUDIT.DQ_RULE_MASTER` stores configuration only; `RULE_TYPE` is matched to
reviewed fixed SQL predicates and no metadata text is executed as SQL. The
deployment seeds the following enabled rules:

| Dataset | Rules |
| --- | --- |
| Member | `MEMBER_ID_NOT_NULL`, `MEMBER_NAME_NOT_NULL`, `DOB_VALID`, `ENROLLMENT_DATE_VALID`, `COUNTRY_NOT_NULL`, `IS_ACTIVE_VALID`, `MEMBER_RECORD_TYPE_VALID` |
| Redemption | `REDEMPTION_ID_NOT_NULL`, `MEMBER_ID_NOT_NULL`, `FEED_DATE_VALID`, `POINTS_NON_NEGATIVE`, `STATUS_VALID`, `MEMBER_EXISTS` |

An enabled unsupported `RULE_TYPE` raises a technical failure. Rule-level
results are written to `AUDIT.DQ_RULE_RESULT` (one outcome per record/rule),
and `AUDIT.DQ_EXECUTION` captures run counts, duplicate observations, and
technical status. Invalid records are merged once into
`STAGING.DQ_QUARANTINE` by dataset and stable source record key. Each
quarantine row includes all DQ failure reasons, source lineage, and the
original member line or redemption payload. DQ failures do not fail the task;
SQL/object errors are audited and re-raised.

The member parser uses the source's leading empty field: record type is field
2, ID remains `VARCHAR` in field 4, and the optional postcode is field 13.
`H` rows stay in parsed staging for traceability but are excluded from DQ and
business member output. Enrollment and last-flight dates use `YYYYMMDD`, and
DOB uses `MMDDYYYY` as evidenced by the fixture. `TRY_TO_DATE` preserves
invalid source text and yields NULL for DQ rather than a fallback date.
Redemption arrays are flattened with `LATERAL FLATTEN`; empty arrays produce
no transaction rows.

Duplicate member IDs are not DQ failures. The latest valid arrival wins by
`INGESTED_AT DESC, SOURCE_FILENAME DESC, SOURCE_ROW_NUMBER DESC`, then stable
tie-breakers. `INGESTED_AT` is Snowflake ingestion time, not a
source-provided update time. Duplicate counts are observable in
`DQ_EXECUTION`. Member history uses SCD2 effective times and current-row flags;
it closes a version only when a business attribute changes, including country,
and does not create history versions for unchanged profiles. Age is derived at
processing time; missing last-flight dates produce NULL `STALE_MEMBER`.
Redemptions are deduplicated by ID, checked against the updated member current
table, and merged idempotently; rejected/unmatched transactions retain their
original JSON and lineage in quarantine. The final processing procedure
rechecks membership and records any unmatched transaction as a DQ failure
before filtering eligible transactions into the core fact.

These are local static SQL-shape checks, not Snowflake integration tests:

```powershell
python -m pytest
```

Live verification remains necessary for Snowflake Scripting compilation,
permissions/task ownership, graph behavior, task history/retry semantics,
MERGE execution, and production source value domains. The project does not
deploy or execute these scripts against a live Snowflake account. Status
values (`COMPLETED`/`PENDING`) and active flags (`A`/`I`) are based on the
supplied sample and should be confirmed with source owners. Document-level
handling for missing/non-array redemption arrays and curated analytics
products remain out of scope. Phase 7 adds file-stage incremental processing
and controlled manual orchestration; scheduled execution remains out of scope.

## Phase 6A-6C: country routing, movement, and reconciliation

After deploying Phase 3 and Phase 4-5, deploy the country configuration,
dedicated audit, routing procedure, and suspended downstream task:

```powershell
snow sql --connection <connection_name> --filename sql/processing/deploy_country_routing.sql
```

Then deploy the movement audit, reconciliation procedure/audit, and suspended
reconciliation task:

```powershell
snow sql --connection <connection_name> --filename sql/processing/deploy_country_movement_reconciliation.sql
```

The script seeds the exact approved alpha-3 country list (`USA`, `IND`, `GBR`,
`CAN`, `AUS`, `DEU`, `FRA`, `JPN`, `SGP`, `NZL`, `ZAF`, `BRA`, `MEX`, `ARE`,
`SAU`, `KOR`, `ITA`, `ESP`, `NLD`, `CHE`). Its `MERGE` preserves each
administrator's `IS_ACTIVE` flag and existing target name on redeployment.
Before routing, the procedure fails closed and records an audit error if it
finds duplicate codes, missing approved codes, unapproved entries, or target
names that do not exactly match `MEMBER_<COUNTRY_CODE>`, or null active flags.
The procedure uses only the allowlist and passes a validated configured
identifier through Snowflake `IDENTIFIER()` binding.

Country tables are created lazily with `LIKE SKYPOINTS_DB.CORE.MEMBER_CURRENT`
only for an active approved country with at least one current member. Valid
current records are merged first. Within one transaction, obsolete rows are
then removed from other country tables. A failed merge rolls back the output
changes, preserving the previous route. `MEMBER_HISTORY` is read by no routing
mutation and remains exclusively maintained by Phase 4-5.

Missing, unsupported, and inactive country destinations are not routed.
Instead, one idempotent record per member/routing condition is merged into
the existing `STAGING.DQ_QUARANTINE` table under dataset `MEMBER_ROUTING`, with
the original source line, a full current-member JSON snapshot, and the reason
`MISSING_COUNTRY`, `UNSUPPORTED_COUNTRY`, or `INACTIVE_COUNTRY`.
An existing country-table row for such a member is preserved until the member
has a valid destination; rows are still removed when their member no longer
exists in `MEMBER_CURRENT`.

**Phase 6B — country movement synchronization.** The existing routing
procedure is also the movement synchronization; there is no duplicate
movement task. It snapshots prior physical membership and writes
member-level action/status details to `AUDIT.COUNTRY_MOVEMENT_AUDIT`. The
previous country is a comma-separated list if pre-existing data has a member
in multiple country tables. A failed movement transaction marks started audit
entries `FAILED` after rollback.

**Phase 6C — validation and reconciliation.**
`AUDIT.SP_VALIDATE_COUNTRY_ROUTING()` performs read-only routing checks for
valid-current membership, duplicate/orphan/wrong-country rows, invalid
destinations, unapproved country tables, configuration integrity, and country
table column compatibility with `CORE.MEMBER_CURRENT`. It stores one result
per check in `AUDIT.COUNTRY_RECONCILIATION_AUDIT`, returns an overall status,
and does not repair discrepancies.

`TASK_COUNTRY_RECONCILIATION` follows `TASK_COUNTRY_ROUTING`; the routing task
remains after `TASK_REDEMPTION_PROCESSING`. Both use `SKYPOINTS_ETL_WH`, are
suspended on deployment, and have no schedule. Manually execute the full graph:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/execute_country_routing.sql
```

After deploying Phase 7, this compatibility execution script calls the
unified run procedure. It uses the managed run guard and cleans up task
suspension after success or failure. For initial Phase 3-6C manual runs before
Phase 7 deployment, use the older Phase-specific execution scripts only with
the understanding that their cleanup behavior is less comprehensive.

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/monitor_country_routing.sql
```

The monitor script shows task history, configuration and table row-count
metadata, routing and movement audit history, reconciliation checks, and
routing quarantine reasons. Reconciliation can also be run independently:

```sql
CALL SKYPOINTS_DB.AUDIT.SP_VALIDATE_COUNTRY_ROUTING();
```

Phase 6A-6C tests are static contract tests only:

```powershell
python -m pytest -q tests/test_phase6_country_routing.py tests/test_phase6bc_country_movement_reconciliation.py
```

Live Snowflake verification is required for DDL/procedure compilation,
`IDENTIFIER()` binding, task ownership, transaction behavior, and
reconciliation results. Reconciliation reports but does not repair
discrepancies. Concurrent independent graph runs are not a supported operating
mode. Existing country tables with manually changed schemas are not altered
automatically.

## Phase 7B-7D: unified execution, recovery, and monitoring

Deploy in dependency order after Phase 2 infrastructure is available:

1. `sql/orchestration/deploy_ingestion_task_graph.sql`
2. `sql/processing/deploy_ingestion_dq_and_business_transformation.sql`
3. `sql/processing/deploy_country_routing.sql`
4. `sql/processing/deploy_country_movement_reconciliation.sql`
5. `sql/orchestration/deploy_unified_pipeline.sql`

Use the same task-owning role for the graph and unified procedures. Deployment
does not execute tasks; the root and all descendants are left suspended, with
no schedule. Run the entire Phase 3-6C graph only through the controlled
entry-point script:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/execute_unified_pipeline.sql
```

`AUDIT.SP_RUN_COMPLETE_PIPELINE()` acquires a singleton run guard, resumes
descendants in reverse dependency order, manually triggers the member-ingestion
root and waits for graph completion, captures the Snowflake graph run ID and
task outcomes in `AUDIT.PIPELINE_RUN_AUDIT`, and suspends the root and
descendants after both success and failure. It reports blocked overlapping
managed runs and re-raises a failed graph after cleanup. Direct concurrent
execution outside this entry point is not supported.

The Phase 4-5 procedures incrementally select files with no successful
checkpoint for the current stage. `AUDIT.ETL_FILE_STAGE_STATUS` identifies a
file by dataset, source filename, content key, and stage, and retains the most
recent status and run ID. `STARTED` and `FAILED` stages are eligible for
reprocessing. Parse/DQ and business writes are merge-based; member current and
history updates are transactional, and redemption facts are idempotent. The
country routing task still synchronizes the current member set on each graph
run. Raw `COPY INTO` uses Snowflake load metadata without `FORCE`; standard
load-history retention is finite (commonly 64 days), and is not a permanent
source-file ledger.

For recovery, inspect `monitor_unified_pipeline.sql` and Snowflake task history,
fix the source or operational failure, then run the same entry point again.
Successful file/stage checkpoints are skipped, while incomplete stages are
retried; idempotent merges handle a prior commit whose checkpoint update did
not complete. Do not remove raw data or audit history to force a retry. If
client/session loss leaves `PIPELINE_RUN_CONTROL.STATUS = 'RUNNING'`, verify
that task history shows no active graph and suspend the descendants before an
operator clears the stale lock.

Run consolidated operational monitoring with:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/monitor_unified_pipeline.sql
```

The queries report recent graph and task outcomes/durations, run comparisons,
ingested source files and row counts, stage-level progress and failures, DQ
valid/invalid/duplicate counts, quarantine totals, live core-table totals,
country routing/movement counts, reconciliation status, and task/procedure
errors. `SKYPOINTS_DB.AUDIT.PIPELINE_RUN_AUDIT`,
`PIPELINE_RUN_CONTROL`, and `ETL_FILE_STAGE_STATUS` are the principal Phase 7
audit objects; country and Phase 4-5 details remain in their existing audit
tables.

Task graphs do not provide a single transaction across stages. Each procedure
commits independently; the member current/history mutation is transactional,
but a later failure does not roll back prior tasks. Checkpoints and idempotent
merges enable safe reruns but do not guarantee exactly-once behavior across S3,
Snowflake COPY metadata, task history, and all audit writes. Snowflake runtime
verification is still required for procedure/task compilation, privileges,
graph waiting and history semantics, and lock behavior. Local static tests do
not deploy or execute SQL.

## Phase 2 infrastructure reference (already provisioned)

The remaining sections describe the earlier infrastructure setup for
reference only. They are not steps in the Phase 3 task graph deployment above.

DCM Project object definitions belong under `sources/definitions/`; Snowflake
CLI does not upload SQL files from this directory. Phase 2 keeps the database,
schemas, warehouse, file formats, raw tables, and external stages in DCM.
Snowflake's DCM `DEFINE PIPE` feature is Preview, so the two pipes are created
separately with conventional `CREATE PIPE` statements under `sql/ingestion/`.

### Existing Phase 2 deployment order

Deploy these steps in order:

1. **Account-level storage integration.** Set the S3 bucket and prefix
   placeholders consistently in
   [create_s3_storage_integration.sql](./create_s3_storage_integration.sql)
   and `sources/definitions/02_raw_ingestion.sql`. Run the account-level script
   with a role that can create storage integrations (typically `ACCOUNTADMIN`):

   ```powershell
   snow sql --connection <connection_name> --filename sql/create_s3_storage_integration.sql
   ```

   The integration requires the AWS IAM role ARN. After the integration is
   created, inspect `DESC INTEGRATION SKYPOINTS_S3_STORAGE_INT`. Configure the
   AWS role trust relationship with `STORAGE_AWS_IAM_USER_ARN` as the trusted
   principal and `STORAGE_AWS_EXTERNAL_ID` as the `sts:ExternalId` condition:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": { "AWS": "<STORAGE_AWS_IAM_USER_ARN>" },
         "Action": "sts:AssumeRole",
         "Condition": {
           "StringEquals": {
             "sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID>"
           }
         }
       }
     ]
   }
   ```

   Grant that AWS role only `s3:ListBucket` for the configured prefixes and
   `s3:GetObject` / `s3:GetObjectVersion` for objects under them. Do not put
   AWS credentials in this repository.

2. **DCM-managed objects.** Use the root README's DCM workflow to bootstrap
   the host schema, create the project, review `snow dcm plan`, and deploy.
   The integration must exist before DCM creates the external stages.

3. **Standalone pipes.** After the stages and raw tables exist, execute both
   pipe scripts with an appropriately privileged Snowflake connection:

   ```powershell
   snow sql --connection <connection_name> --filename sql/ingestion/create_member_profile_pipe.sql
   snow sql --connection <connection_name> --filename sql/ingestion/create_redemption_pipe.sql
   ```

   Each script creates one independent pipe with `AUTO_INGEST = TRUE`. Re-run
   DCM after changing DCM-managed objects; pipe definitions are managed by
   these standalone scripts.

4. **S3 event notifications.** Run `DESC PIPE
   SKYPOINTS_DB.RAW.MEMBER_PROFILE_PIPE` and `DESC PIPE
   SKYPOINTS_DB.RAW.REDEMPTION_PIPE`; inspect the `notification_channel`
   returned for each. Snowflake may reuse a notification queue for multiple
   pipes in the same AWS region; do not assume one queue per pipe.

   In the S3 bucket notification configuration, route `ObjectCreated` events
   for the members prefix to the member pipe's queue and events for the
   redemptions prefix to the redemption pipe's queue. If both pipes report the
   same queue, configure two rules targeting that queue with the disjoint
   prefixes. If the channels differ, target each rule to its corresponding
   queue. Do not add a prefix-less `ObjectCreated` rule or overlapping prefix
   rules for the same event types. Check existing bucket notifications too:
   prefixes such as `members/` and `members/archive/` overlap.

### Phase 2 raw member record preservation

The assessment's formal member specification includes `Post_Code`, while the
supplied flat-file sample does not. The member CSV file format therefore uses
`FIELD_DELIMITER = NONE`, with the normal newline record delimiter, and the
pipe copies `$1` directly to `SOURCE_RECORD`. `MULTI_LINE = FALSE`, no field
enclosure, and `ESCAPE_UNENCLOSED_FIELD = NONE` keep line boundaries literal.
This supported CSV configuration loads each complete physical source line as
one `VARCHAR`: the leading pipe, `H`/`D` indicator, delimiters, and all fields
are preserved, regardless of field count or later source-layout changes. No
field parsing or business transformation occurs in this phase.

The fixture intentionally contains both the sample layout and a record with
an additional field, representing the formal `Post_Code` discrepancy. Blank
or otherwise malformed files still fail visibly under `ON_ERROR = SKIP_FILE`;
correct and republish a failed file under a new S3 object key.

Redemption files use a JSON file format with `STRIP_OUTER_ARRAY = FALSE`.
Each top-level JSON document is copied intact to `PAYLOAD` (`VARIANT`), so
nested redemption arrays—including empty arrays—are not flattened.

### Phase 2 local and account smoke tests

Run the local fixture and definition checks before deploying:

```powershell
python -m pytest
```

After configuring S3 notifications, upload the fixtures under their matching
prefixes using unique object names. Verify the raw member lines and metadata:

```sql
SELECT SOURCE_RECORD, SOURCE_FILENAME, SOURCE_ROW_NUMBER,
       SOURCE_FILE_CONTENT_KEY, INGESTED_AT
FROM SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW
ORDER BY INGESTED_AT, SOURCE_ROW_NUMBER;
```

Verify redemption documents and metadata:

```sql
SELECT PAYLOAD, SOURCE_FILENAME, SOURCE_ROW_NUMBER,
       SOURCE_FILE_CONTENT_KEY, INGESTED_AT
FROM SKYPOINTS_DB.RAW.REDEMPTION_RAW
ORDER BY INGESTED_AT, SOURCE_ROW_NUMBER;
```

These queries should show the `H` and `D` member lines unchanged, and each
redemption document as one `VARIANT` value.

### Phase 2 pipe monitoring

Check each pipe's current execution state, pending files, and notification
queue:

```sql
SELECT SYSTEM$PIPE_STATUS('SKYPOINTS_DB.RAW.MEMBER_PROFILE_PIPE');
SELECT SYSTEM$PIPE_STATUS('SKYPOINTS_DB.RAW.REDEMPTION_PIPE');
```

Review recent load outcomes and parse errors (the history function covers the
last 14 days):

```sql
SELECT FILE_NAME, LAST_LOAD_TIME, STATUS, ROW_COUNT, ERROR_COUNT,
       FIRST_ERROR_MESSAGE
FROM TABLE(SKYPOINTS_DB.INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW',
    START_TIME => DATEADD('DAY', -7, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;
```

Use the redemption raw table name in the query to inspect that pipe. Failed
files are not partially loaded; correct and republish them under a new object
key. AWS resources, IAM trust, event notifications, and live Snowflake
deployment must be configured and verified per environment.
