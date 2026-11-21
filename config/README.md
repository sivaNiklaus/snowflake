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

`manage.py` reads these YAML target settings. `dev.yml` contains the
repository's verified DEV database, warehouse, S3 bucket/prefixes, and
integration; configure `connection_name` to match a local Snowflake CLI
profile. The staging and production files remain templates without matching
manifest targets. These files are not consumed automatically by standalone
SQL or the test-only GitHub Actions workflow. Keep credentials and tokens in
the approved secret-management system; do not commit them.
