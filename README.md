# SkyPoints ETL

SkyPoints ETL is a Snowflake-based data platform foundation for loyalty-member
profiles and partner-airline redemption transactions. This repository is
currently **Phase 1: Project Foundation**. It contains project scaffolding and
initial Snowflake infrastructure definitions; it does not ingest or transform
data.

## Business problem

SkyPoints receives daily pipe-delimited member profile files and JSON redemption
transactions from airline partners. The planned platform will validate these
sources, reconcile duplicate members and country migrations, and publish
country-specific data for analytics. It is designed to evolve toward very large
data volumes without coupling infrastructure definitions to transformation
code.

## Architecture overview

```text
Partner profile files ─┐
                       ├─> AWS S3 (future) ─> Snowflake RAW
Redemption JSON ───────┘                       │
                                               v
                                   STAGING -> CORE -> ANALYTICS
                                               │
                                  AUDIT / operational history
```

The diagram describes the target direction, not implemented services. Phase 1
defines the Snowflake database, schemas, and a small auto-suspending warehouse.
S3 resources, ingestion, data quality rules, transformations, and country
outputs are future work.

## Technology stack

- **Snowflake** for the planned data platform.
- **Snowflake CLI DCM Projects** for declarative Snowflake object definitions.
  The DCM manifest and definition layout follows the current format
  (`manifest_version: 2`); it was checked with Snowflake CLI 3.34.0.
- **AWS S3** as a future source landing zone.
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
│   └── bootstrap_dcm.sql
├── sources/
│   └── definitions/
│       └── 01_foundation.sql
├── src/
│   ├── ingestion/
│   ├── transformations/
│   └── validations/
├── tests/
│   └── test_project_foundation.py
├── .env.example
├── .gitignore
├── manifest.yml
├── README.md
└── requirements.txt
```

DCM Projects require SQL object definitions under `sources/definitions/`;
Snowflake CLI uploads files from `sources/`, not from the repository's `sql/`
directory. Therefore the managed database, schemas, and warehouse are defined
in `sources/definitions/01_foundation.sql`. The separate `sql/` folder holds
the one-time SQL bootstrap needed to create the database and schema that will
contain the DCM project object.

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
Do not put credentials in this repository. `.env.example` lists configuration
names only; Snowflake CLI connection profiles and your organization's approved
secret manager are responsible for authentication.

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
by the project, so inspect the plan before deploying. The bootstrap SQL creates
only the database and `AUDIT` schema required to host the DCM project; DCM then
manages the declared database, five project schemas, and warehouse. Snowflake
also creates a default `PUBLIC` schema with a database; it is not managed by
this project's definitions.

## Deployment strategy

Phase 1 intentionally does **not** deploy from GitHub Actions. CI checks the
Python test suite only. For Snowflake, use the Snowflake CLI DCM lifecycle:
configure a connection, bootstrap the DCM host schema, create the DCM project,
run `snow dcm plan`, review the changeset, and explicitly run
`snow dcm deploy`. A later phase can add account-authenticated deployment after
the target environments, role model, and CI secret management are agreed.

AWS ingestion is also intentionally not configured: no buckets, IAM roles,
Snowflake storage integrations, or credentials are provisioned in this phase.

## Future implementation phases

1. **Foundation (current):** repository, tests, DCM project configuration, and
   initial Snowflake objects.
2. **Source ingestion:** S3 landing conventions and ingestion for pipe-delimited
   member files and partner redemption JSON.
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

The first two commands validate the local foundation. The Snowflake `plan`
command requires a configured Snowflake account and the target placeholders
must be replaced first; it has not been run as part of this phase.

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
- No AWS resources, authentication credentials, ingestion logic, Snowpipe,
  Streams, Tasks, or ETL transformations are included in Phase 1.
- Snowflake syntax and DCM project structure were checked against Snowflake's
  current documentation and the official CLI template. Account-specific DCM
  planning and deployment remain unverified until connected to a real account.
