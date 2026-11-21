# SkyPoints ETL runbook

This runbook covers initial setup, deployment, execution, monitoring, and
recovery. It does not execute Snowflake SQL automatically. Use an authorized
Snowflake CLI connection and follow the organization's change and secret
management procedures.

## Initial environment setup

1. Install the Snowflake CLI version required by the root README and configure
   a named local connection. Credentials belong in the CLI profile or the
   organization's approved secret store, never in this repository.
2. Review `config/dev.yml`, `config/staging.yml`, or `config/prod.yml`. These
   files are documentation templates, not automatically consumed settings.
   Configure each environment's database, warehouse, connection name, storage
   integration, S3 bucket, and prefixes where marked.
3. Configure the S3 bucket and prefixes consistently in
   `sources/definitions/02_raw_ingestion.sql` and
   `sql/00_setup/create_s3_storage_integration.sql`. Configure the IAM role
   ARN only in the account-level integration script. Establish the required
   AWS role trust and least-privilege S3 access outside this repository.
4. Bootstrap the existing DCM host database/schema only when needed using
   `sql/00_setup/bootstrap_dcm.sql`. The `SKYPOINTS_DB` database and parent
   `AUDIT` schema are deliberately excluded from DCM object management.

## DCM deployment versus standalone SQL

Use the DCM workflow for the definitions in `sources/definitions/`: review the
plan before deployment because DCM may alter or drop objects it manages. The
standalone account-level S3 storage integration and pipe scripts are run
separately. Task, stored-procedure, and audit deployments are also standalone
SQL files under `sql/`; they are not part of the DCM project upload.

The GitHub Actions workflow runs Python static tests only. It does not deploy
to Snowflake.

## Deployment order

Complete prerequisite setup before deploying task orchestration:

1. Create/verify the storage integration with
   `sql/00_setup/create_s3_storage_integration.sql`.
2. Bootstrap the DCM host as needed, review the DCM plan, and deploy the
   definitions under `sources/definitions/`.
3. Create the member and redemption pipes with the two scripts in
   `sql/01_ingestion/pipes/`.
4. Deploy the Phase 3 graph with
   `sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql`.
5. Deploy Phase 4-5 with
   `sql/03_processing/dq_and_transformation/deploy_ingestion_dq_and_business_transformation.sql`.
6. Deploy Phase 6 country routing with
   `sql/03_processing/country_routing/deploy_country_routing.sql`, followed
   by reconciliation with
   `sql/03_processing/country_movement_reconciliation/deploy_country_movement_reconciliation.sql`.
7. Deploy unified Phase 7 orchestration last with
   `sql/04_unified_pipeline/deploy_unified_pipeline.sql`.

Deployment scripts are rerunnable where implemented, but inspect each script
and the Snowflake change plan before redeployment. Do not infer rollback from
DDL deployment or task execution; Snowflake does not provide a transaction
spanning this pipeline.

## Execute the unified pipeline

The preferred complete Phase 3-6C entry point is:

```powershell
snow sql --connection <connection_name> --filename sql/04_unified_pipeline/execute_unified_pipeline.sql
```

This calls `SKYPOINTS_DB.AUDIT.SP_RUN_COMPLETE_PIPELINE()`. It guards against
overlapping controlled runs, resumes descendants in reverse dependency order,
manually triggers and waits for the root task, then suspends tasks and records
the run and graph IDs. The root and descendants are suspended by default.
There is no scheduled execution.

Phase-specific execution scripts under
`sql/02_orchestration_ingestion/` and `sql/03_processing/` are for isolated
operations and troubleshooting, not a substitute for the unified end-to-end
entry point.

## Monitor successful and failed runs

Use `sql/04_unified_pipeline/monitor_unified_pipeline.sql` for recent graph
runs, task-level history, file checkpoints, ingestion/DQ totals, live core
table totals, country routing counts, reconciliation status, and failure
details. The task-history lookback is limited to seven days; pipeline and
domain audit records retain their own history.

For diagnosis, correlate the pipeline audit `RUN_ID` / `GRAPH_RUN_ID` with
`AUDIT.INGESTION_AUDIT`, `AUDIT.DQ_EXECUTION`, `AUDIT.DQ_RULE_RESULT`,
`AUDIT.ETL_FILE_STAGE_STATUS`, `AUDIT.PHASE45_AUDIT`,
`AUDIT.COUNTRY_ROUTING_AUDIT`, `AUDIT.COUNTRY_MOVEMENT_AUDIT`, and
`AUDIT.COUNTRY_RECONCILIATION_AUDIT`. Use the failure drill-down in the
unified monitoring script to identify failed task names and task/procedure
errors. Persistent quarantine rows and the per-run DQ failure counts are
separate views; do not treat lifetime quarantine totals as a run delta.

## Failure recovery and task suspension

1. Read the failed row in `AUDIT.PIPELINE_RUN_AUDIT` and the task-history
   failure details. Identify the first failed stage and inspect its audit and
   file-stage checkpoint records.
2. Preserve invalid records in quarantine and retain source files; correct the
   underlying configuration, privilege, or data issue before retrying.
3. The unified runner attempts to suspend the graph on both success and
   failure and release the run guard. Confirm the tasks are suspended with
   `monitor_unified_pipeline.sql`; inspect `AUDIT.PIPELINE_RUN_CONTROL` for an
   active run before attempting another invocation.
4. A failed stage's file checkpoints are eligible for retry; successful
   checkpoints and idempotent merges protect earlier successful work. Re-run
   the unified entry point after confirming no graph is still active. Do not
   manually mark a failed file or run as successful.
5. If task suspension, audit finalization, or lock release reported an error,
   do not force a new run. Inspect task history and audit state, then have an
   operator resolve the specific task/lock condition using the existing
   suspension procedure and appropriate privileges. After confirming no graph
   is active, the procedure can be called explicitly:

   ```sql
   CALL SKYPOINTS_DB.AUDIT.SP_SUSPEND_PIPELINE_DESCENDANTS();
   ```

   Review its return value for task-level suspension errors. Do not clear a
   stale run lock until task history confirms the graph is no longer active.

Snowflake transactions apply within individual procedures only. Raw ingestion,
task runs, and all audit writes do not participate in one global transaction;
later failure does not roll back already committed earlier stages. The
checkpoint and merge behavior supports safe retries but does not constitute a
cross-system exactly-once guarantee.
