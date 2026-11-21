# SkyPoints ETL

SkyPoints ETL is a Snowflake-based data platform for loyalty-member profiles
and partner-airline redemption transactions. It contains the Phase 1
foundation, Phase 2 S3/Snowflake access infrastructure, Phase 3 raw ingestion,
the combined **Phase 4-5: metadata-driven DQ and business processing** task
graph, and **Phase 6A-6C: country routing, movement synchronization, and
reconciliation**.

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

## Combined Phase 4-5 processing

The ingestion, DQ, and business-transformation deployment in
[`sql/processing/deploy_ingestion_dq_and_business_transformation.sql`](sql/processing/deploy_ingestion_dq_and_business_transformation.sql)
creates parsed staging, audit/DQ, quarantine, and core objects, plus SQL
procedures and four downstream tasks. Deploy Phase 3 first, then Phase 4-5
with the same task-owning role:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/deploy_ingestion_task_graph.sql
snow sql --connection <connection_name> --filename sql/processing/deploy_ingestion_dq_and_business_transformation.sql
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
snow sql --connection <connection_name> --filename sql/orchestration/execute_ingestion_dq_and_business_transformation.sql
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
[`sql/orchestration/monitor_ingestion_dq_and_business_transformation.sql`](sql/orchestration/monitor_ingestion_dq_and_business_transformation.sql)
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
snow sql --connection <connection_name> --filename sql/processing/deploy_country_routing.sql
```

Then deploy the movement audit, reconciliation procedure/audit, and suspended
reconciliation task:

```powershell
snow sql --connection <connection_name> --filename sql/processing/deploy_country_movement_reconciliation.sql
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
`AUDIT.COUNTRY_RECONCILIATION_AUDIT`; the procedure returns an overall
`PASSED` or `FAILED` result and does not repair data.

`TASK_COUNTRY_RECONCILIATION` follows `TASK_COUNTRY_ROUTING`, which remains
after `TASK_REDEMPTION_PROCESSING`. Both tasks use `SKYPOINTS_ETL_WH`, are
created suspended, and have no schedule. Manually run the complete graph:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/execute_country_routing.sql
```

The script resumes descendants in reverse dependency order, executes the
existing suspended root with `AWAIT`, and suspends descendants again after
success.
After a failure, inspect task/audit history and suspend descendants manually
if execution did not reach cleanup. Monitoring queries are in
[`sql/orchestration/monitor_country_routing.sql`](sql/orchestration/monitor_country_routing.sql).
They report task history, config and table row-count metadata, routing and
movement audit, reconciliation results, and quarantine reasons. To run
reconciliation independently, call
`CALL SKYPOINTS_DB.AUDIT.SP_VALIDATE_COUNTRY_ROUTING();` and inspect the
persistent check rows using the monitor queries.

Country routing and reconciliation remain account-side Snowflake operations;
local tests are static and do not establish SQL runtime correctness.
Reconciliation reports discrepancies without repairing them. Concurrent
independent manual graph runs are not a supported operating mode. An existing
country table with a manually altered schema is reported by reconciliation
and routing SQL failures remain visible.

## Technology stack

- **Snowflake** for the planned data platform.
- **Snowflake CLI DCM Projects** for declarative Snowflake object definitions.
  The DCM manifest and definition layout follows the current format
  (`manifest_version: 2`); it was checked with Snowflake CLI 3.34.0.
- **AWS S3** as the member and redemption source landing zone.
- **Python** for future utilities and tests.
- **GitHub** and **GitHub Actions** for source control and foundational CI.

## Repository structure

```text
.
├── .github/
│   └── workflows/
│       └── ci.yml
├── config/
│   └── README.md
├── sql/
│   ├── README.md
│   ├── bootstrap_dcm.sql
│   ├── create_s3_storage_integration.sql
│   ├── ingestion/
│   │   ├── create_member_profile_pipe.sql
│   │   ├── create_redemption_pipe.sql
│   │   ├── load_member_profile.sql
│   │   ├── load_redemption.sql
│   │   ├── validate_member_profile.sql
│   │   └── validate_redemption.sql
│   ├── processing/
│   │   ├── deploy_ingestion_dq_and_business_transformation.sql
│   │   └── deploy_country_routing.sql
│   └── orchestration/
│       ├── deploy_ingestion_task_graph.sql
│       ├── execute_ingestion_task_graph.sql
│       ├── execute_ingestion_dq_and_business_transformation.sql
│       ├── execute_country_routing.sql
│       ├── monitor_ingestion_task_graph.sql
│       ├── monitor_ingestion_dq_and_business_transformation.sql
│       └── monitor_country_routing.sql
├── sources/
│   └── definitions/
│       ├── 01_foundation.sql
│       └── 02_raw_ingestion.sql
├── src/
│   ├── ingestion/
│   ├── transformations/
│   └── validations/
├── tests/
│   ├── test_project_foundation.py
│   ├── test_copy_ingestion.py
│   ├── test_raw_ingestion.py
│   ├── test_task_graph.py
│   ├── test_phase45_static.py
│   ├── test_phase6_country_routing.py
│   └── fixtures/
│       ├── members/member_sample.dat
│       └── redemptions/redemption_sample.json
├── .env.example
├── .gitignore
├── manifest.yml
├── README.md
└── requirements.txt
```

DCM Projects require object definitions under `sources/definitions/`;
Snowflake CLI uploads files from `sources/`, not from `sql/`. The DCM
definitions contain the existing database, schemas, warehouse, file formats,
raw tables, and external stages. Phase 3 orchestration and the standalone
load/validation scripts are separate SQL under `sql/`; they do not recreate
those objects.

## Local development setup

### Python tests

From the repository root in PowerShell:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m pytest
```

The only initial Python dependency is `pytest`, used by the CI workflow. Add
runtime or transformation libraries only when a later phase needs them.

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
snow sql --connection <connection_name> --filename sql/bootstrap_dcm.sql
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
DCM then manages the declared database, five project schemas, warehouse, and
Phase 2 raw-ingestion objects. Snowflake also creates a default `PUBLIC`
schema with a database; it is not managed by this project's definitions.

## Existing infrastructure deployment

The Phase 1/2 infrastructure setup is documented in [sql/README.md](sql/README.md).
Do not rerun it as part of Phase 3. In particular, Phase 3 does not execute
the existing pipe creation scripts.

## Phase 3 execution

With the existing stages, formats, warehouse, and raw tables available,
deploy the task graph:

```powershell
snow sql --connection <connection_name> --filename sql/orchestration/deploy_ingestion_task_graph.sql
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
snow sql --connection <connection_name> --filename sql/orchestration/execute_ingestion_task_graph.sql
```

That script manually triggers the root task with:

```sql
EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT;
```

This command waits for the Phase 3 graph. If Phase 4-5 has also been deployed,
use `execute_ingestion_dq_and_business_transformation.sql` instead; it temporarily resumes the
descendants and suspends them again after a successful run. No daily schedule
is configured or in scope. Monitor task state and audit rows using
`sql/orchestration/monitor_ingestion_task_graph.sql`.
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
7. **Scale and operations:** scheduling, workload tuning, backfills, and
   operational automation; out of scope for the current phase.

## Validation commands

```powershell
python -m pip install -r requirements.txt
python -m pytest
snow sql --connection <connection_name> --filename sql/orchestration/monitor_ingestion_task_graph.sql
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
- Parsing and business processing scan accumulated parsed history on each
  manual run; a separately designed incremental strategy may be needed at
  larger scale.
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
