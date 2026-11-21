# Configuration

`.env.example` lists environment variable names and default S3 prefixes for
local tooling. It contains no account-specific bucket name or credentials. Do
not commit `.env` files, Snowflake CLI connection profiles, or cloud secrets.
Prefix values must end in `/`.

For Snowflake deployment, configure authentication in a local Snowflake CLI
connection profile and use your organization's approved secret-management
process. DCM SQL definitions do not read `.env`: set the bucket and prefixes
in the stage URLs in `sources/definitions/02_raw_ingestion.sql`, and use the
same locations in `sql/00_setup/create_s3_storage_integration.sql`. Set the
IAM role ARN only in the account-level SQL script. Do not put credentials in
this repository.

`dev.yml`, `staging.yml`, and `prod.yml` are documentation-oriented
configuration templates. They are not consumed automatically by the SQL
scripts, Snowflake CLI, or the test-only GitHub Actions workflow. Replace
marked values for the target environment and keep secrets in the approved
secret-management system; do not commit credentials or tokens.
