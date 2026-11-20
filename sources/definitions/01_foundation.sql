-- Foundation only: no ingestion, orchestration, or transformation objects.
DEFINE DATABASE SKYPOINTS_DB
    COMMENT = 'SkyPoints ETL platform database';

DEFINE SCHEMA SKYPOINTS_DB.RAW
    COMMENT = 'Unmodified source data landing zone';

DEFINE SCHEMA SKYPOINTS_DB.STAGING
    COMMENT = 'Validated and standardized intermediate data';

DEFINE SCHEMA SKYPOINTS_DB.CORE
    COMMENT = 'Conformed SkyPoints business entities';

DEFINE SCHEMA SKYPOINTS_DB.ANALYTICS
    COMMENT = 'Analytics-ready data products';

DEFINE SCHEMA SKYPOINTS_DB.AUDIT
    COMMENT = 'Deployment and operational audit records';

DEFINE WAREHOUSE SKYPOINTS_ETL_WH
    WITH
        WAREHOUSE_SIZE = XSMALL
        AUTO_SUSPEND = 60
        AUTO_RESUME = TRUE
        INITIALLY_SUSPENDED = TRUE
        COMMENT = 'Small auto-suspending warehouse for SkyPoints ETL workloads';
