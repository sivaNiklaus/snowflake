# Configuration

`.env.example` lists environment variable names for future local tooling. It
contains no values or credentials. Do not commit `.env` files, Snowflake CLI
connection profiles, or cloud secrets.

For Phase 1, configure Snowflake authentication in a local Snowflake CLI
connection profile and use your organization's approved secret-management
process. AWS-specific runtime configuration will be added when S3 ingestion is
implemented.
