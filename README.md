# SkyPoints ETL

SkyPoints ETL is a Snowflake-based data platform for loyalty-member profiles
and partner-airline redemption transactions. It contains the Phase 1
foundation, Phase 2 S3/Snowflake access infrastructure, Phase 3 raw ingestion,
the combined **Phase 4-5: metadata-driven DQ and business processing** task
graph, and **Phase 6A-6C: country routing, movement synchronization, and
reconciliation**, with **Phase 7B-7D: unified manual orchestration, recovery,
and monitoring**.

## Business problem

SkyPoints receives daily pipe-delimited member profile files and JSON redemption
transactions from airline partners. The planned platform will validate these
sources, reconcile duplicate members and country migrations, and publish
country-specific data for analytics. It is designed to evolve toward very large
data volumes without coupling infrastructure definitions to transformation
code.

## Architecture overview

```text
Member files -> existing S3 stage -> raw ingestion -> MEMBER_PROFILE_RAW
Redemption JSON -> existing S3 stage -> raw ingestion -> REDEMPTION_RAW
  -> TASK_INGESTION_VALIDATION -> parse/normalize -> metadata-driven DQ
  -> valid member records -> MEMBER_CURRENT / MEMBER_HISTORY
  -> valid redemption records -> REDEMPTION_FACT
  -> invalid records/transactions -> DQ_QUARANTINE
```

Phase 3's existing `COPY INTO` path and immutable raw table structures remain
unchanged. The member raw table stores each complete source line in
`SOURCE_RECORD`; the redemption raw table stores each JSON document in
`PAYLOAD`. The downstream graph parses typed staging rows, evaluates configured
and allowlisted DQ rules, retains all failures in quarantine, and processes
valid data into core tables.

## Lifecycle commands

`manage.py` is the project entry point for deployment and operations:

```powershell
python manage.py deploy --target dev
python manage.py run --target dev
python manage.py monitor --target dev
python manage.py destroy --target dev
```

Configure `snowflake.connection_name` in `config/dev.yml` to match a local
Snowflake CLI connection before running these commands. DEV's database,
warehouse, bucket, prefixes, and integration are populated from the verified
repository definitions. Provision the account-level storage integration once
with the configured IAM role before deploying; the manager validates it but
does not create or delete it. The manager validates the connection role against
the DCM target owner before deploy/destroy, checks the installed Snowflake CLI
help for the commands and options it will use, then invokes `snow` through
subprocesses. It does not use a Python Snowflake connector.

Deploy runs `snow dcm create`, `plan`, and (when the plan has changes) `deploy`,
then creates the pipes and deploys Phases 3, 4-5, 6A, 6B-6C, and 7 in
dependency order. It does not run the pipeline and explicitly leaves all nine
tasks suspended. On failure it stops and lists completed steps; rerun after
resolving the reported issue. The standalone scripts are rerunnable except
existing pipes are kept rather than replaced when already present.

`run` invokes the unified Phase 3-6C execution script; `monitor` invokes its
read-only monitoring script. For `destroy`, type `DEV` at the prompt or use
`--yes`. The manager inspects `snow dcm purge --help` and `snow dcm drop --help`
individually before removing any standalone resources. It requires both
commands to document the project directory (`--from`), target, and connection.
For non-interactive purge confirmation it supplies `--force` only when purge
help documents it; otherwise it uses a documented `--yes` option or stops.

Destroy suspends tasks leaf-to-root, removes standalone objects in reverse
deployment order, runs DCM purge, and only then drops the DCM project. The
summary reports **DCM purge completed**, **DCM project dropped**, and
**Complete destruction completed** as separate milestones. Purge failure stops
before drop. If purge reports the project is already absent, the manager does
not count that as a successful purge because managed entities may remain. If
drop fails after purge, it reports the partial teardown and does not report
complete destruction. The DEV destroy policy permits deletion of the
project-owned warehouse. It always protects the database, parent `AUDIT`
schema, storage integration, S3 data, and AWS IAM resources. `prod`, if later
configured, requires both `--yes` and `--allow-prod-destroy`.

The current manifest defines only `DEV`. `staging` and `prod` are rejected
until real manifest targets and complete configuration files exist. The
current development host had no Snowflake CLI installed, so command options
could not be checked locally; runtime help validation prevents guessed flags.
See the [resource inventory](docs/resource-inventory.md) and
[runbook](docs/runbook.md) for ownership, sequencing, and recovery details.

## Combined Phase 4-5 processing

The ingestion, DQ, and business-transformation deployment in
[`sql/03_processing/dq_and_transformation/deploy_ingestion_dq_and_business_transformation.sql`](sql/03_processing/dq_and_transformation/deploy_ingestion_dq_and_business_transformation.sql)
creates parsed staging, audit/DQ, quarantine, and core objects, plus SQL
procedures and four downstream tasks. Deploy Phase 3 first, then Phase 4-5
with the same task-owning role:

```powershell
snow sql --connection <connection_name> --filename sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql
snow sql --connection <connection_name> --filename sql/03_processing/dq_and_transformation/deploy_ingestion_dq_and_business_transformation.sql
```

The complete manually triggered graph is:

```text
TASK_MEMBER_INGESTION
  -> TASK_REDEMPTION_INGESTION
  -> TASK_INGESTION_VALIDATION
  -> TASK_PARSE_AND_NORMALIZE
  -> TASK_DQ_VALIDATION
  -> TASK_MEMBER_PROCESSING
  -> TASK_REDEMPTION_PROCESSING
```

All tasks use `SKYPOINTS_ETL_WH`, share the deploying role as owner, and have no
schedule. Deployment leaves the full graph suspended. The execution script
temporarily resumes descendants in dependency order, manually triggers the
suspended root, waits for the full graph, then suspends descendants again:

```powershell
snow sql --connection <connection_name> --filename sql/03_processing/dq_and_transformation/execute_ingestion_dq_and_business_transformation.sql
```

### Parsing and data quality

Member records are split only in staging. Field 2 is the `H`/`D` indicator,
fields 3-12 are source attributes, and optional `Post_Code` is field 13.
Header rows remain traceable in parsed staging but are excluded from business
DQ and core processing. Member IDs remain `VARCHAR`. Enrollment and last-flight
dates use `YYYYMMDD`; DOB uses `MMDDYYYY`, as shown by the fixture. Safe date
conversion retains invalid source text and yields NULL for DQ to report.
Original records and ingestion lineage are retained.

Redemption documents are expanded with `LATERAL FLATTEN` on
`PAYLOAD:redemptions`. An empty array yields no transactions and is not
quarantined as an invalid transaction. Each flattened transaction retains its
original payload, array index, filename, row number, content key, and ingestion
timestamp.

`AUDIT.DQ_RULE_MASTER` is the metadata configuration surface. The SQL engine
maps only reviewed `RULE_TYPE` values to fixed expressions; it never executes
SQL text from metadata, and an enabled unsupported type fails the task.
Inspect configuration with:

```sql
SELECT RULE_ID, DATASET_NAME, RULE_TYPE, TARGET_COLUMN, IS_ENABLED
FROM SKYPOINTS_DB.AUDIT.DQ_RULE_MASTER
ORDER BY DATASET_NAME, RULE_ID;
```

The deployment seeds member rules for required ID/name/country, valid DOB and
enrollment date, active flag, and data record type. Redemption rules cover ID,
member ID, feed date, non-negative points, supported status, and member
existence. Current accepted member active codes are `A`/`I`; redemption
statuses are `COMPLETED`/`PENDING`, matching available feed evidence. Change
these policies in reviewed engine code rather than storing arbitrary SQL in
metadata.

Every enabled rule emits a pass/fail row in `AUDIT.DQ_RULE_RESULT`. All failed
rules for a source record are grouped into one `STAGING.DQ_QUARANTINE` row with
an array of reasons and original source data. Quarantine is merged by dataset
and stable source-record key, so retries do not duplicate it. Record-level DQ
failures do not stop valid records from continuing. `AUDIT.DQ_EXECUTION`
records per-run totals, valid/invalid counts, duplicate counts, and execution
status.

### Member and redemption processing

For duplicate valid member IDs, the winning profile is selected by descending
`INGESTED_AT`, `SOURCE_FILENAME`, and `SOURCE_ROW_NUMBER`, followed by stable
lineage/source-record tie-breakers. `INGESTED_AT` is Snowflake ingestion time,
**not** a source-provided profile update timestamp. Duplicate counts are
recorded for observability; repeated IDs are not DQ errors.

`CORE.MEMBER_CURRENT` is merged idempotently. `CORE.MEMBER_HISTORY` maintains
effective dates and a current-row indicator, closes the prior version when a
business attribute changes, and does not add a history version for an
unchanged profile. Country changes are preserved in history; country-specific
outputs are outside this phase. Age is derived on the processing date.
`STALE_MEMBER` is true only when a non-null last-flight date is older than 90
days; a missing last-flight date yields NULL rather than an invented value.

Redemptions are deduplicated by `REDEMPTION_ID` using latest arrival and
deterministic lineage tie-breakers, checked against the resulting current
member table, and merged idempotently into `CORE.REDEMPTION_FACT`. Invalid and
unmatched transactions remain quarantined with original JSON and lineage. The
final processing step rechecks referential integrity against committed current
members and records any unmatched transaction as a DQ failure before merging.

Use
[`sql/03_processing/dq_and_transformation/monitor_ingestion_dq_and_business_transformation.sql`](sql/03_processing/dq_and_transformation/monitor_ingestion_dq_and_business_transformation.sql)
for task history, procedure audits, DQ counts, rule outcomes, quarantine, and
core referential-integrity queries. Monitoring and execution remain separate
from deployment. Static tests do not deploy or execute SQL against Snowflake.

## Phase 6A-6C: country routing, movement, and reconciliation

Phase 6A routes current `CORE.MEMBER_CURRENT` rows into lazily created
`CORE.MEMBER_<COUNTRY_CODE>` outputs. The routing configuration and audit
tables are in `AUDIT`; invalid or inactive destinations are recorded in the
existing `STAGING.DQ_QUARANTINE` structure. The router does not change
`MEMBER_HISTORY` or take over Phase 4-5 SCD Type 2 processing.

Deploy Phase 6A after Phase 3 and Phase 4-5:

```powershell
snow sql --connection <connection_name> --filename sql/03_processing/country_routing/deploy_country_routing.sql
```

Then deploy the movement audit, reconciliation procedure/audit, and suspended
reconciliation task:

```powershell
snow sql --connection <connection_name> --filename sql/03_processing/country_movement_reconciliation/deploy_country_movement_reconciliation.sql
```

`AUDIT.COUNTRY_ROUTING_CONFIG` is seeded idempotently with exactly these
approved ISO 3166-1 alpha-3 codes:

```text
USA, IND, GBR, CAN, AUS, DEU, FRA, JPN, SGP, NZL,
ZAF, BRA, MEX, ARE, SAU, KOR, ITA, ESP, NLD, CHE
```

Redeployment inserts missing approved entries but does not update existing
`TARGET_TABLE` or administrator-managed `IS_ACTIVE` values. Before routing,
the procedure fails closed and records an audit error if it finds duplicate
country codes, missing approved entries, unapproved countries, or target names
that do not exactly match `MEMBER_<COUNTRY_CODE>`, or null active flags. Codes
outside this allowlist are never routed, even if an extra configuration row
is added manually.
Country tables are created only when an approved, active country has current
members; each new table is created `LIKE CORE.MEMBER_CURRENT`. Routing uses
the configured target only after configuration integrity checks, then uses
Snowflake `IDENTIFIER()` binding for the identifier.

On each run the router normalizes country codes with `TRIM` and `UPPER`,
routes only approved active countries, and quarantines missing,
unsupported, or inactive countries as `MISSING_COUNTRY`, `UNSUPPORTED_COUNTRY`,
or `INACTIVE_COUNTRY`. The quarantine row retains the source record and a
variant snapshot of all current member columns. A stable member/reason key
makes repeated quarantine merges idempotent.

For country movement, the procedure validates destinations, creates needed
tables, and merges valid current member rows before deleting stale rows from
other country outputs. The merges and cleanup are one transaction: an insert
or update failure rolls back country-output changes and preserves the prior
country copy. Invalid destinations are quarantined and not routed; any existing
country output for that member is preserved until the member has a valid,
active, approved destination. Rows for members no longer present in
`MEMBER_CURRENT` are still removed. Each execution is recorded in
`AUDIT.COUNTRY_ROUTING_AUDIT`, including inserted, updated, removed, routed,
quarantined, and failed-run counts.

**Phase 6B — country movement synchronization.** The existing routing task
also synchronizes member country movements; it is not duplicated in a second
movement task. Before synchronization it snapshots
prior country-table membership. `AUDIT.COUNTRY_MOVEMENT_AUDIT` records each
member's previous country, destination, action (`MOVED`, `INSERTED`,
`SYNCHRONIZED`, or `QUARANTINED`), and outcome. Movement entries are marked
`FAILED` if the transaction rolls back. The previous country is a comma-
separated list if pre-existing output contains the member in multiple tables.

**Phase 6C — validation and reconciliation.** This phase adds
`AUDIT.SP_VALIDATE_COUNTRY_ROUTING()`. It checks that valid
current members are routed exactly once to the matching country, detects
duplicate/orphan/wrong-country and invalid-destination routes, flags
unapproved country tables and configuration defects, and compares each
existing approved country table's column structure with `MEMBER_CURRENT`.
Results are persisted by run and check in
`AUDIT.COUNTRY_RECONCILIATION_AUDIT`; a clean run returns `PASSED`. If any
check fails, the procedure preserves the individual check rows and raises an
error, causing the reconciliation task and complete graph to fail. The
procedure does not repair data.

`TASK_COUNTRY_RECONCILIATION` follows `TASK_COUNTRY_ROUTING`, which remains
after `TASK_REDEMPTION_PROCESSING`. Both tasks use `SKYPOINTS_ETL_WH`, are
created suspended, and have no schedule. Manually run the complete graph:

```powershell
snow sql --connection <connection_name> --filename sql/03_processing/country_routing/execute_country_routing.sql
```

The script resumes descendants in reverse dependency order, executes the
controlled graph runner, and attempts cleanup after both success and failure.
Deploy Phase 7 before using this compatibility entry point. For complete run
history and task-level metrics, use
[`sql/04_unified_pipeline/monitor_unified_pipeline.sql`](sql/04_unified_pipeline/monitor_unified_pipeline.sql).
Phase 6-specific monitoring queries remain in
[`sql/03_processing/country_routing/monitor_country_routing.sql`](sql/03_processing/country_routing/monitor_country_routing.sql).
They report task history, config and table row-count metadata, routing and
movement audit, reconciliation results, and quarantine reasons. To run
reconciliation independently, call
`CALL SKYPOINTS_DB.AUDIT.SP_VALIDATE_COUNTRY_ROUTING();` and inspect
`AUDIT.COUNTRY_RECONCILIATION_AUDIT`; a failed check raises after its results
are persisted.

Country routing and reconciliation remain account-side Snowflake operations;
local tests are static and do not establish SQL runtime correctness.
Reconciliation reports discrepancies without repairing them. Concurrent
independent manual graph runs are not a supported operating mode. An existing
country table with a manually altered schema is reported by reconciliation
and routing SQL failures remain visible.

## Phase 7B-7D: unified execution, recovery, and monitoring

Phase 7 adds a single controlled entry point for the existing Phase 3-6C task
graph. Deploy the scripts in this order, using the same task-owning role:

1. `sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql`
2. `sql/03_processing/dq_and_transformation/deploy_ingestion_dq_and_business_transformation.sql`
3. `sql/03_processing/country_routing/deploy_country_routing.sql`
4. `sql/03_processing/country_movement_reconciliation/deploy_country_movement_reconciliation.sql`
5. `sql/04_unified_pipeline/deploy_unified_pipeline.sql`

Deployment leaves the root and descendants suspended and defines no schedule.
To run the complete pipeline, call the controlled entry point:

```powershell
snow sql --connection <connection_name> --filename sql/04_unified_pipeline/execute_unified_pipeline.sql
```

`AUDIT.SP_RUN_COMPLETE_PIPELINE()` guards against overlapping managed runs,
resumes descendants in reverse dependency order, manually triggers and waits
for the root graph, records its graph run ID and outcome in
`AUDIT.PIPELINE_RUN_AUDIT`, then suspends all tasks after success or failure.
Task-level execution states and errors remain available through Snowflake task
history. The runner re-raises a failed graph after attempting cleanup, so the
original failure is not reported as success.

Phase 4-5 downstream processing is incremental by source file and stage.
`AUDIT.ETL_FILE_STAGE_STATUS` keys checkpoints by dataset, source filename,
content key, and stage. Only a `SUCCEEDED` checkpoint is excluded from work;
`STARTED` or `FAILED` files are eligible on the next full-graph run. Parse and
DQ use idempotent merges, member current/history changes use a transaction and
idempotent SCD2 logic, and redemption facts use an idempotent merge. Country
routing continues to reconcile the current member set, including stale-output
removal. Raw ingestion still uses Snowflake `COPY INTO` load history and does
not force reloads; load-history retention is finite (commonly 64 days), so
long-term deduplication/backfill policy must be managed with the Snowflake
account's COPY history and source object retention.

For recovery, inspect task history and the unified monitor, correct the source
or permission issue, then run `execute_unified_pipeline.sql` again. Failed or
interrupted downstream stages remain eligible; completed stages are skipped.
Do not delete raw or audit records to force a retry. If a client is cancelled
and `PIPELINE_RUN_CONTROL` remains `RUNNING`, first verify that no graph is
active in task history and suspend descendants; only then may an operator
clear the stale control row and record the manual intervention.

The consolidated monitor includes pipeline/task history, ingestion files and
rows, stage checkpoints, per-run DQ/quarantine counts (distinct failed records
from that run's rule results), lifetime quarantine totals, current core totals,
country movement counts, reconciliation results, and failed-task details:

```powershell
snow sql --connection <connection_name> --filename sql/04_unified_pipeline/monitor_unified_pipeline.sql
```

These are not distributed transactions: each task and procedure commits its
own work. The member current/history mutation is transactional, but the graph
as a whole is not rolled back when a later task fails. Checkpoints and
idempotent merges make reruns safe; they do not provide exactly-once semantics
across S3, Snowflake task history, and every audit write. A connection loss
could leave the run-control row stale and requires the guarded manual recovery
above. No Snowflake deployment or runtime execution is performed by the local
static tests.

## Technology stack

- **Snowflake** for the planned data platform.
- **Snowflake CLI DCM Projects** for declarative Snowflake object definitions.
  The DCM manifest and definition layout follows the current format
  (`manifest_version: 2`); it was checked with Snowflake CLI 3.34.0.
- **AWS S3** as the member and redemption source landing zone.
- **Python** for lifecycle orchestration and static tests.
- **GitHub** and **GitHub Actions** for source control and foundational CI.

## Repository structure

```text
.
├── .github/
│   └── workflows/
│       └── ci.yml
├── config/
│   ├── README.md
│   ├── dev.yml
│   ├── staging.yml
│   └── prod.yml
├── docs/
│   ├── architecture.md
│   ├── resource-inventory.md
│   └── runbook.md
├── sql/
│   ├── README.md
│   ├── 00_setup/
│   │   ├── bootstrap_dcm.sql
│   │   └── create_s3_storage_integration.sql
│   ├── 01_ingestion/
│   │   ├── pipes/
│   │   │   ├── create_member_profile_pipe.sql
│   │   │   └── create_redemption_pipe.sql
│   │   ├── load/
│   │   │   ├── load_member_profile.sql
│   │   │   └── load_redemption.sql
│   │   └── validate/
│   │       ├── validate_member_profile.sql
│   │       └── validate_redemption.sql
│   ├── 02_orchestration_ingestion/
│   │   ├── deploy_ingestion_task_graph.sql
│   │   ├── execute_ingestion_task_graph.sql
│   │   └── monitor_ingestion_task_graph.sql
│   ├── 03_processing/
│   │   ├── dq_and_transformation/
│   │   │   ├── deploy_ingestion_dq_and_business_transformation.sql
│   │   │   ├── execute_ingestion_dq_and_business_transformation.sql
│   │   │   └── monitor_ingestion_dq_and_business_transformation.sql
│   │   ├── country_routing/
│   │   │   ├── deploy_country_routing.sql
│   │   │   ├── execute_country_routing.sql
│   │   │   └── monitor_country_routing.sql
│   │   └── country_movement_reconciliation/
│   │       └── deploy_country_movement_reconciliation.sql
│   ├── 04_unified_pipeline/
│   │   ├── deploy_unified_pipeline.sql
│   │   ├── execute_unified_pipeline.sql
│   │   └── monitor_unified_pipeline.sql
│   └── 05_lifecycle/
│       ├── suspend_pipeline_tasks.sql
│       ├── destroy_phase7.sql
│       ├── destroy_phase6_reconciliation.sql
│       ├── destroy_phase6_routing.sql
│       ├── destroy_phase45.sql
│       ├── destroy_phase3.sql
│       └── destroy_pipes.sql
├── sources/
│   └── definitions/
│       ├── 01_foundation.sql
│       └── 02_raw_ingestion.sql
├── tests/
│   ├── fixtures/
│   │   ├── members/member_sample.dat
│   │   └── redemptions/redemption_sample.json
│   └── test_*.py
├── .env.example
├── .gitignore
├── manifest.yml
├── manage.py
├── README.md
└── requirements.txt
```

DCM Projects require object definitions under `sources/definitions/`;
Snowflake CLI uploads files from `sources/`, not from `sql/`. The DCM
definitions manage the project schemas, warehouse, file formats, raw tables,
and external stages. The existing `SKYPOINTS_DB` database and parent `AUDIT`
schema are intentionally outside DCM management. Phase task/procedure
deployment and standalone load/validation scripts are separate SQL under the
numbered `sql/` folders; they do not recreate DCM-managed objects.
`manage.py` reads `config/` settings. They are not automatically loaded by
Snowflake or the CI workflow. The staging and production files remain
unconfigured templates; the existing GitHub Actions workflow is test-only.

## Local development setup

### Python tests

From the repository root in PowerShell:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m pytest
```

`pytest` runs the static test suite, and `PyYAML` parses lifecycle target
configuration. The CI workflow runs tests only; it does not deploy to
Snowflake.

### Snowflake CLI

Install the Snowflake CLI and check its version:

```powershell
uv tool install snowflake-cli
snow --version
```

DCM Projects require Snowflake CLI 3.24.0 or later. This project's manifest
format was verified against CLI 3.34.0 and Snowflake's official DCM project
documentation. The `DEV` target in `manifest.yml` is configured with account
identifier `GIMFDUR-DY25356`, project name
`SKYPOINTS_DB.AUDIT.SKYPOINTS_DCM_PROJECT_DEV`, and project owner
`ACCOUNTADMIN`. Use a named Snowflake CLI connection for that account and
confirm the configured owner has the needed privileges. Configure the
connection using the
[Snowflake CLI connection guide](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/connect).
Do not put credentials in this repository. `.env.example` contains a blank
bucket setting and default prefixes only; set the bucket and prefixes in the
SQL templates before deployment. Snowflake CLI connection profiles and your
organization's approved secret manager are responsible for authentication.

### First-time DCM setup

The `DEV` target uses the configured account identifier, project name, and
project owner documented above; it is not a placeholder template. Confirm that
the Snowflake CLI connection targets that account and that the configured
owner has the required privileges. The DCM project object is located in
`SKYPOINTS_DB.AUDIT`, so bootstrap that database and schema first using an
authorized Snowflake CLI connection:

```powershell
snow sql --connection <connection_name> --filename sql/00_setup/bootstrap_dcm.sql
```

Then create the DCM project, preview its planned changes, and deploy only after
review:

```powershell
snow dcm create --from . --target DEV --connection <connection_name>
snow dcm plan --from . --target DEV --connection <connection_name>
snow dcm deploy --from . --target DEV --connection <connection_name>
```

The `plan` and `deploy` commands require a working Snowflake account connection
and appropriate privileges. DCM deployment can alter or drop objects managed
by the project, so inspect the plan before deploying. The bootstrap SQL
creates only the database and `AUDIT` schema required to host the DCM project;
the existing database and `AUDIT` parent schema remain outside DCM management.
DCM manages the declared `RAW`, `STAGING`, `CORE`, and `ANALYTICS` schemas,
warehouse, and Phase 2 raw-ingestion objects. Snowflake also creates a default
`PUBLIC` schema with a database; it is not managed by this project's definitions.

## Existing infrastructure deployment

The Phase 1/2 infrastructure setup is documented in [sql/README.md](sql/README.md).
Do not rerun it as part of Phase 3. In particular, Phase 3 does not execute
the existing pipe creation scripts.

## Phase 3 execution

With the existing stages, formats, warehouse, and raw tables available,
deploy the task graph:

```powershell
snow sql --connection <connection_name> --filename sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql
```

Deployment creates an audit table, SQL stored procedures, and three tasks in
sequence: member ingestion (root), redemption ingestion after member success,
and validation after redemption success. Each task uses `SKYPOINTS_ETL_WH`.
Deployment resumes only the child tasks in dependency order. The root remains
suspended because it has no schedule; deployment does not execute the graph.
Task creation is separate from DCM-managed infrastructure; it does not alter
Phase 1/2 definitions or recreate stages, formats, or raw tables.

For Phase 3 standalone manual execution, run:

```powershell
snow sql --connection <connection_name> --filename sql/02_orchestration_ingestion/execute_ingestion_task_graph.sql
```

That script manually triggers the root task with:

```sql
EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT;
```

This command waits for the Phase 3 graph. If Phase 4-5 has also been deployed,
use `execute_ingestion_dq_and_business_transformation.sql` instead; it temporarily resumes the
descendants and suspends them again after a successful run. No daily schedule
is configured or in scope. Monitor task state and audit rows using
`sql/02_orchestration_ingestion/monitor_ingestion_task_graph.sql`. These
Phase-specific scripts are useful for isolated operation; use the Phase 7
unified entry point for the complete Phase 3-6C graph.
Detailed deployment privileges, expected audit fields, failure recovery, and
the Phase 1/2 account setup are documented in [sql/README.md](sql/README.md).
For the complete Phase 3-5 graph, deploy and execute as described above.

The procedures preserve Snowflake file-load deduplication: they use the
existing `COPY INTO` load history, `ON_ERROR = 'ABORT_STATEMENT'`, and no
`FORCE = TRUE`. Coordinate the existing Phase 2 auto-ingest pipes and do not
run them concurrently against the same prefixes as this task graph.

No Phase 1/2 infrastructure was changed, and no live Snowflake deployment or
execution is performed by the local static tests.

## Phase boundaries

1. **Foundation:** repository, tests, DCM project configuration, and initial
   Snowflake objects.
2. **S3/Snowflake access infrastructure:** configured source landing and
   external stages.
3. **Raw data ingestion:** task-graph orchestration, raw-table validation, and
   operational task auditing.
4-5. **Metadata-driven DQ and business processing:** parsing,
   validation, quarantine, member current/history, and redemption facts.
6A. **Metadata-driven country routing (current):** approved-country member
   outputs; curated analytics products remain future work.
7. **Operations and reliability:** Phase 7B-7D adds controlled manual
   orchestration, incremental stage checkpoints, safe reruns, and unified
   monitoring. Scheduling, workload tuning, and external retry/alert services
   remain out of scope.

## Validation commands

```powershell
python -m pip install -r requirements.txt
python -m pytest -q
snow sql --connection <connection_name> --filename sql/04_unified_pipeline/monitor_unified_pipeline.sql
```

Python tests validate static SQL shape and fixtures. The Snowflake scripts
require a connection with the required task, procedure, audit-table,
warehouse, stage, and raw-table privileges. They have not been deployed or
run against an account by the test suite.

## Assumptions and limitations

- The initial warehouse is `XSMALL`, starts suspended, auto-resumes when used,
  and auto-suspends after 60 seconds. Adjust the size and policies for the
  actual workload and account controls.
- The DCM project object is hosted in `SKYPOINTS_DB.AUDIT`. The first-time
  bootstrap therefore requires privileges to create that database and schema,
  and to create a DCM project there.
- The `DEV` manifest target uses the account identifier, project name, and
  project owner documented above. Verify those account-specific settings and
  privileges before DCM deployment; the manifest is not modified by Phase 3.
- AWS resources and credentials are not provisioned by this repository.
  Storage integration, bucket event notifications, and actual Snowflake
  deployment require account-specific setup and have not been run here.
- Each member source line, including its leading delimiter, remains verbatim in
  immutable `SOURCE_RECORD`; parsed fields are stored separately in staging.
- Snowflake COPY load metadata provides same-table file de-duplication for
  files recorded as loaded. Inspect COPY history before any intentional
  backfill or reprocessing.
- Header rows are excluded from business processing; malformed dates preserve
  their source strings and are quarantined by DQ.
- Accepted status and active-indicator values are based on the supplied
  sample and must be confirmed against a complete partner contract.
- Parsing, DQ, and business processing use per-file stage checkpoints; the
  checkpoints do not replace backup, retention, or account-level COPY history
  management.
- Empty redemption arrays intentionally produce no transaction rows. A
  document with a missing/non-array `redemptions` property is not expanded
  into a transaction and is not currently quarantined at document level.
- Curated country analytics products beyond Phase 6C reconciliation and Phase 7
  scheduling/automation remain out of scope.
- Task procedures record SQL execution failures in the audit table and
  re-raise them. Platform failures before procedure invocation are available
  through Snowflake task history.
- Snowflake syntax and DCM project structure were checked against Snowflake's
  current documentation and the official CLI template. Account-specific DCM,
  task graph deployment, and live execution remain unverified until connected
  to a real account.
