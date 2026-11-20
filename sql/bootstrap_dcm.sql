-- DCM project objects are schema-scoped, so create their host database/schema first.
CREATE DATABASE IF NOT EXISTS SKYPOINTS_DB
    COMMENT = 'SkyPoints ETL platform database';

CREATE SCHEMA IF NOT EXISTS SKYPOINTS_DB.AUDIT
    COMMENT = 'Deployment and operational audit records';
