# Configuration

`config/<target>.yml` is the source of truth for account, database, warehouse,
integration, bucket, and prefixes. `.env.example` contains only the optional
IAM role ARN needed when the configured integration is absent. The lifecycle
does not automatically load `.env` files; provide the variable in the process
environment. Do not commit `.env` files, Snowflake CLI connection profiles, or
cloud secrets.

For Snowflake deployment, configure authentication in a local Snowflake CLI
connection profile and use your organization's approved secret-management
process. `manage.py` renders DCM definitions and setup SQL from
`config/<target>.yml`; the repository files are templates, not direct
environment configuration. If the storage integration is missing, set the
environment variable named by `storage.aws_role_arn_env` (DEV:
`SKYPOINTS_AWS_IAM_ROLE_ARN`) to the AWS IAM role ARN. The variable is needed
only for creation and is never written to the repository.

`manage.py` reads all target-specific Snowflake and storage values from the
YAML target. `dev.yml` contains the verified DEV settings and connection name
`dev`; the Snowflake CLI profile must point to the configured account. Staging
and production remain templates without matching manifest targets. The
test-only GitHub Actions workflow never connects to Snowflake.
