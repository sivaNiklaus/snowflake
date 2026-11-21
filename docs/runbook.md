# SkyPoints ETL runbook

This runbook covers initial setup, deployment, execution, monitoring, and
recovery; commands only execute when explicitly invoked. Use an authorized
Snowflake CLI connection and follow the organization's change and secret
management procedures.

## Lifecycle commands

The lifecycle interface shells out to Snowflake CLI; it does not use a
Snowflake Python connector:

```powershell
python manage.py deploy --target dev
python manage.py run --target dev
python manage.py monitor --target dev
python manage.py destroy --target dev
```

Set `snowflake.connection_name` in `config/dev.yml` to the name of a local
Snowflake CLI connection. The checked-in DEV file intentionally leaves this
machine-specific value unconfigured. `manage.py` validates that value, the
DCM manifest target, the configured storage integration and S3 stage URLs
before contacting Snowflake. Staging and production are unavailable until
their manifest targets and configurations are real; the command surface does
not imply those environments are deployable.

Deploy performs a connection/role preflight against the configured DCM
project owner, validates relevant `snow` and per-command `snow dcm --help`
options, creates (or recognizes an existing) DCM project, plans and deploys
DCM-managed definitions, then deploys in this order:

1. Both standalone ingestion pipes.
2. Phase 3 ingestion task graph.
3. Phase 4-5 parsing, DQ, and business processing.
4. Phase 6A country routing.
5. Phase 6B-6C reconciliation.
6. Phase 7 unified pipeline controls.
7. Final task suspension from leaf to root.

Deployment never calls the pipeline runner. Existing pipes are left unchanged
when the CLI reports they already exist; the manager does not replace them or
claim to validate their definition drift. All completed and skipped steps are
reported, and a failure stops later steps. Because this is not one Snowflake
transaction, a failed deployment may leave completed objects in place; fix
the reported issue and rerun the idempotent steps.

The standalone SQL deployment order is:

```powershell
snow sql --connection <connection_name> --filename sql/01_ingestion/pipes/create_member_profile_pipe.sql
snow sql --connection <connection_name> --filename sql/01_ingestion/pipes/create_redemption_pipe.sql
snow sql --connection <connection_name> --filename sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql
snow sql --connection <connection_name> --filename sql/03_processing/dq_and_transformation/deploy_ingestion_dq_and_business_transformation.sql
snow sql --connection <connection_name> --filename sql/03_processing/country_routing/deploy_country_routing.sql
snow sql --connection <connection_name> --filename sql/03_processing/country_movement_reconciliation/deploy_country_movement_reconciliation.sql
snow sql --connection <connection_name> --filename sql/04_unified_pipeline/deploy_unified_pipeline.sql
snow sql --connection <connection_name> --filename sql/05_lifecycle/suspend_pipeline_tasks.sql
```

For DCM, the manager first validates the installed command help, then invokes
the repository-documented `snow dcm create`, `snow dcm plan`, and
`snow dcm deploy` commands for target `DEV` and the configured connection.
The manager requires each subcommand's help to document `--from`, `--target`,
and `--connection` before it supplies `--from .`, `--target DEV`, and
`--connection <connection_name>`. If the installed CLI documents a different
syntax, the manager stops instead of guessing flags.

`run` invokes the Phase 7 unified execution script. `monitor` invokes its
read-only monitoring script. For destroy, the selected target and exact
resource groups are printed before confirmation. Type the target name (for
DEV, `DEV`) or pass `--yes`. A future configured `prod` additionally requires
both `--yes` and `--allow-prod-destroy`. DEV's explicit destroy policy permits
removal of `SKYPOINTS_ETL_WH`.

Before standalone deletion, the manager inspects `snow dcm purge --help` and
`snow dcm drop --help` separately. Both must document `--from`, `--target`, and
`--connection`; the manager supplies the current project directory, configured
target, and named connection using only those documented options. Purge help
must also document a non-interactive confirmation option: `--force` is used
only when purge help explicitly lists it; otherwise a documented `--yes` is
used. If either command or required option is unsupported, the process stops
before standalone resources are removed.

After help and role preflight, destroy suspends all nine tasks leaf-to-root,
then removes Phase 7, Phase 6B-6C, Phase 6A, Phase 4-5, Phase 3, and pipe
objects in reverse deployment order. It runs DCM purge only after standalone
teardown succeeds, then runs DCM drop only after purge succeeds. The summary
distinguishes **DCM purge completed**, **DCM project dropped**, and
**Complete destruction completed**. A purge failure prevents drop. If purge
reports the project is already absent, the manager does not count it as a
successful purge; managed entities may remain, so complete destruction is not
reported. If drop fails after purge, the summary records the successful purge
but not a dropped project or completed destruction.

The DCM purge removes project-managed entities, grants, and attachments; drop
removes the DCM project object and deployment history. DCM teardown includes
the project-owned warehouse only when the target's destroy policy permits it.
It never removes the database, parent `AUDIT` schema, storage integration, S3
data, AWS IAM resources, or bucket notifications. Destroy is irreversible for
the listed audit and quarantine tables; it is not a data-backup mechanism.

For exact ownership and the complete named resource list, see
[`resource-inventory.md`](resource-inventory.md).

## Initial environment setup

1. Install the Snowflake CLI version required by the root README and configure
   a named local connection. Credentials belong in the CLI profile or the
   organization's approved secret store, never in this repository.
2. Review the target YAML files. `manage.py` consumes them; set the local
   Snowflake CLI connection name in `config/dev.yml`. The S3 bucket, prefixes,
   database, warehouse, and integration are matched against checked-in
   definitions. Staging/prod placeholders are not deployable.
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

`python manage.py deploy --target dev` runs this DCM and standalone SQL
sequence, including the final leaf-to-root task suspension. Do not separately
execute the per-phase deployment scripts as part of the same lifecycle run.

Standalone deployment scripts are rerunnable where implemented, but inspect
the DCM change plan before deployment. Do not infer rollback from DDL
deployment or task execution; Snowflake does not provide a transaction
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
