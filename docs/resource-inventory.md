# Snowflake resource inventory and ownership

This inventory is based on the current DCM definitions and standalone SQL
deployment scripts. `manage.py destroy` displays these groups before
confirmation. The default project database and parent `AUDIT` schema are never
dropped.

## DCM-managed resources

Defined in `sources/definitions/01_foundation.sql` and
`sources/definitions/02_raw_ingestion.sql`:

| Resource type | Names |
| --- | --- |
| Schemas | `SKYPOINTS_DB.RAW`, `SKYPOINTS_DB.STAGING`, `SKYPOINTS_DB.CORE`, `SKYPOINTS_DB.ANALYTICS` |
| Warehouse | `SKYPOINTS_ETL_WH` |
| File formats | `SKYPOINTS_DB.RAW.MEMBER_PROFILE_CSV`, `SKYPOINTS_DB.RAW.REDEMPTION_JSON` |
| Raw tables | `SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW`, `SKYPOINTS_DB.RAW.REDEMPTION_RAW` |
| External stages | `SKYPOINTS_DB.RAW.MEMBER_S3_STAGE`, `SKYPOINTS_DB.RAW.REDEMPTION_S3_STAGE` |
| DCM project registration | `SKYPOINTS_DB.AUDIT.SKYPOINTS_DCM_PROJECT_DEV` in the protected parent schema |

The DEV destroy policy explicitly permits deleting the project-managed
warehouse. Staging and production have no manifest targets and cannot be used.
The `SKYPOINTS_DB` database and `SKYPOINTS_DB.AUDIT` parent schema are not DCM
resources in this project.

## Standalone SQL resources

| Deployment area | Resources |
| --- | --- |
| Account setup | `SKYPOINTS_S3_STORAGE_INT` is created by `sql/00_setup/create_s3_storage_integration.sql`; it is account-scoped and protected from destroy. The bootstrap script creates `SKYPOINTS_DB` and `SKYPOINTS_DB.AUDIT` only if absent; both are protected. |
| Ingestion pipes | `SKYPOINTS_DB.RAW.MEMBER_PROFILE_PIPE`, `SKYPOINTS_DB.RAW.REDEMPTION_PIPE` |
| Phase 3 | `AUDIT.INGESTION_AUDIT`; `RAW.SP_RUN_MEMBER_INGESTION()`, `RAW.SP_RUN_REDEMPTION_INGESTION()`, `RAW.SP_RUN_INGESTION_VALIDATION()`; tasks `TASK_MEMBER_INGESTION`, `TASK_REDEMPTION_INGESTION`, `TASK_INGESTION_VALIDATION` |
| Phase 4-5 | `AUDIT.PHASE45_AUDIT`, `AUDIT.ETL_FILE_STAGE_STATUS`, `AUDIT.DQ_RULE_MASTER`, `AUDIT.DQ_EXECUTION`, `AUDIT.DQ_RULE_RESULT`; `STAGING.MEMBER_PROFILE_PARSED`, `STAGING.REDEMPTION_PARSED`, `STAGING.DQ_QUARANTINE`; `CORE.MEMBER_CURRENT`, `CORE.MEMBER_HISTORY`, `CORE.REDEMPTION_FACT`; four processing procedures and four processing tasks |
| Phase 6A | `AUDIT.COUNTRY_ROUTING_CONFIG`, `AUDIT.COUNTRY_ROUTING_AUDIT`, `AUDIT.COUNTRY_MOVEMENT_AUDIT`; `CORE.SP_ROUTE_MEMBERS_BY_COUNTRY()`; task `TASK_COUNTRY_ROUTING`; output tables `CORE.MEMBER_USA`, `MEMBER_IND`, `MEMBER_GBR`, `MEMBER_CAN`, `MEMBER_AUS`, `MEMBER_DEU`, `MEMBER_FRA`, `MEMBER_JPN`, `MEMBER_SGP`, `MEMBER_NZL`, `MEMBER_ZAF`, `MEMBER_BRA`, `MEMBER_MEX`, `MEMBER_ARE`, `MEMBER_SAU`, `MEMBER_KOR`, `MEMBER_ITA`, `MEMBER_ESP`, `MEMBER_NLD`, and `MEMBER_CHE` |
| Phase 6B-6C | `AUDIT.COUNTRY_RECONCILIATION_AUDIT`; `AUDIT.SP_VALIDATE_COUNTRY_ROUTING()`; task `TASK_COUNTRY_RECONCILIATION` |
| Phase 7 | `AUDIT.PIPELINE_RUN_AUDIT`, `AUDIT.PIPELINE_RUN_CONTROL`; `AUDIT.SP_RUN_COMPLETE_PIPELINE()`, `AUDIT.SP_SUSPEND_PIPELINE_DESCENDANTS()` |

The complete task graph has exactly nine task objects, in order:

`TASK_MEMBER_INGESTION -> TASK_REDEMPTION_INGESTION ->
TASK_INGESTION_VALIDATION -> TASK_PARSE_AND_NORMALIZE ->
TASK_DQ_VALIDATION -> TASK_MEMBER_PROCESSING ->
TASK_REDEMPTION_PROCESSING -> TASK_COUNTRY_ROUTING ->
TASK_COUNTRY_RECONCILIATION`.

The task graph is not a separate Snowflake object. The routing procedure uses
temporary work tables; those are not persistent destroy targets. No
user-defined functions are created by the current deployment SQL.

## Always protected

- The `SKYPOINTS_DB` database and `SKYPOINTS_DB.AUDIT` parent schema.
- The account-level S3 storage integration.
- The S3 bucket and its objects.
- AWS IAM roles, policies, and bucket notification configuration.
- Resources outside the exact object names listed above.

Destroy drops the explicit standalone tables, including audit and quarantine
history, after task suspension. It does not use `CASCADE` on schemas and does
not modify AWS bucket notifications. Snowflake pipe deletion cannot remove
those external notification rules.

## DCM teardown support

The Snowflake CLI was not installed in the implementation environment, so its
version and command options could not be inspected here. At runtime, the
lifecycle manager requires both `snow dcm purge` and `snow dcm drop`, and
inspects each command's own help before any standalone deletion. Both help
outputs must document the project directory (`--from`), target, and connection
options. Purge help must document a non-interactive confirmation option:
`--force` is passed only when explicitly documented; otherwise a documented
`--yes` is used. Missing commands or required options stop destruction before
standalone resources are removed.

The order is standalone SQL teardown, DCM purge, then DCM drop. Purge removes
managed entities, grants, and attachments; drop removes the project object and
deployment history. Purge failure prevents drop. A missing project response
from purge is not treated as proof that managed entities were removed. The
lifecycle summary records purge, project drop, and complete destruction as
separate milestones; a failed drop after successful purge is partial teardown,
not complete destruction.
