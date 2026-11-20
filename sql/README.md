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

The deployment script is rerunnable and does not resume or schedule tasks.
Newly created tasks are suspended by default. It does not define a schedule.
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

The script resumes the two child tasks but leaves the root suspended. It then
runs the full graph synchronously using this single trigger:

```sql
EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT;
```

The root has no schedule and remains manually triggered. Do not configure a
daily schedule until a manual run and its validation have succeeded. Before
running, ensure the existing auto-ingest pipes are not concurrently consuming
the same S3 prefixes.

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
