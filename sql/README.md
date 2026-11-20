# SQL scripts

Snowflake CLI DCM Projects only reads project definitions from
`sources/definitions/`; see [01_foundation.sql](../sources/definitions/01_foundation.sql).
This directory is reserved for standalone SQL utilities and one-time bootstrap
scripts that are not DCM definitions.

Run [bootstrap_dcm.sql](./bootstrap_dcm.sql) once with an authorized Snowflake
CLI connection to create the database and schema that host the DCM project
object. The DCM project subsequently manages the declared database, schemas,
and warehouse.
