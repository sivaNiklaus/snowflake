# SkyPoints ETL

SkyPoints ETL is a Snowflake-based data platform for loyalty-member profiles
and partner-airline redemption transactions. It contains **Phase 1: Project
Foundation** and **Phase 2: Raw S3-to-Snowflake ingestion**. It does not perform
business validation or transformations.

## Business problem

SkyPoints receives daily pipe-delimited member profile files and JSON redemption
transactions from airline partners. The planned platform will validate these
sources, reconcile duplicate members and country migrations, and publish
country-specific data for analytics. It is designed to evolve toward very large
data volumes without coupling infrastructure definitions to transformation
code.

## Architecture overview

```text
Member files ─> S3 members/ ───────┐
                                   ├─> S3 events -> Snowflake-managed SQS queue(s)
Redemption JSON -> S3 redemptions/ ┘                       │
                                        ┌──────────────────┴─────────────────┐
                                  Member Profile Pipe                 Redemption Pipe
                                        │                                     │
                                MEMBER_PROFILE_RAW                     REDEMPTION_RAW
```

Phase 1 defines the Snowflake database, schemas, and a small auto-suspending
warehouse. Phase 2 uses DCM for file formats, raw tables, and external stages.
The two `CREATE PIPE` statements are separate SQL deployments because DCM's
`DEFINE PIPE` feature is Preview. Snowflake may reuse a notification queue for
multiple pipes in the same AWS region. AWS bucket notifications and IAM trust
are environment-specific setup steps documented in `sql/README.md`.

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
│   └── ingestion/
│       ├── create_member_profile_pipe.sql
│       └── create_redemption_pipe.sql
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
│   ├── test_raw_ingestion.py
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
definitions contain the database, schemas, warehouse, file formats, raw
tables, and external stages. One-time account setup and standalone pipe
creation scripts remain under `sql/`.

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
documentation. Configure a named Snowflake CLI connection using the
[Snowflake CLI connection guide](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/connect).
Do not put credentials in this repository. `.env.example` contains a blank
bucket setting and default prefixes only; set the bucket and prefixes in the
SQL templates before deployment. Snowflake CLI connection profiles and your
organization's approved secret manager are responsible for authentication.

### First-time DCM setup

The example `DEV` target in `manifest.yml` contains clearly marked
account/role/project placeholders. Replace them with values for your Snowflake
account before running DCM commands. The DCM project object is located in
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

## Deployment strategy

Deploy in this order:

1. Configure the S3 bucket and prefixes in the SQL templates. Create the
   account-level storage integration using
   `sql/create_s3_storage_integration.sql`, then use its `DESC INTEGRATION`
   output to finish the AWS IAM trust relationship.
2. Bootstrap the DCM host schema. Create the project, review `snow dcm plan`,
   then run `snow dcm deploy`. This deploys the stages and their tables and
   file formats.
3. Create the pipes with the standalone scripts, after their DCM-managed
   stages/tables exist:

   ```powershell
   snow sql --connection <connection_name> --filename sql/ingestion/create_member_profile_pipe.sql
   snow sql --connection <connection_name> --filename sql/ingestion/create_redemption_pipe.sql
   ```

4. Inspect both pipes' `notification_channel` values and configure S3
   `ObjectCreated` event notifications as described in `sql/README.md`.

The DCM and standalone Snowflake steps require a configured account and
appropriate privileges. AWS buckets, IAM roles, and event notifications are
environment-specific and are not provisioned here. No credentials are stored
in the repository.

## Future implementation phases

1. **Foundation:** repository, tests, DCM project configuration, and initial
   Snowflake objects.
2. **Raw source ingestion (current):** independent Snowpipe auto-ingest for
   pipe-delimited member files and partner redemption JSON.
3. **Validation and audit:** schema, quality, reject, and operational auditing
   rules.
4. **Member and transaction processing:** deduplication, history, and country
   migration handling.
5. **Country-specific outputs:** curated tables and analytics interfaces.
6. **Scale and operations:** workload tuning, observability, backfills, and
   carefully gated automated deployments.

## Validation commands

```powershell
python -m pip install -r requirements.txt
python -m pytest
snow --version
snow dcm plan --from . --target DEV --connection <connection_name>
```

The Python tests validate the local definitions. The Snowflake `plan` command
requires a configured account, the account-level integration, and replacement
of all S3/IAM placeholders; it has not been run as part of this phase.

## Assumptions and limitations

- The initial warehouse is `XSMALL`, starts suspended, auto-resumes when used,
  and auto-suspends after 60 seconds. Adjust the size and policies for the
  actual workload and account controls.
- The DCM project object is hosted in `SKYPOINTS_DB.AUDIT`. The first-time
  bootstrap therefore requires privileges to create that database and schema,
  and to create a DCM project there.
- The `DEV` manifest target is a template, not a usable account configuration.
  The account identifier, project owner role, and project object must be
  verified and replaced by the account administrator.
- AWS resources and credentials are not provisioned by this repository.
  Storage integration, bucket event notifications, and actual Snowflake
  deployment require account-specific setup and have not been run here.
- Each member source line, including its leading delimiter, is retained
  verbatim in `SOURCE_RECORD`; the source is not parsed into columns.
- Header/data interpretation and all business transformations remain future
  work.
- Each redemption top-level JSON document is retained intact in a VARIANT;
  nested arrays are not flattened.
- Snowflake syntax and DCM project structure were checked against Snowflake's
  current documentation and the official CLI template. Account-specific DCM
  planning and deployment remain unverified until connected to a real account.
