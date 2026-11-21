-- DCM project objects are schema-scoped, so create their host database/schema first.
CREATE DATABASE IF NOT EXISTS {{DATABASE}}
    COMMENT = 'SkyPoints ETL platform database';

CREATE SCHEMA IF NOT EXISTS {{DATABASE}}.AUDIT
    COMMENT = 'Deployment and operational audit records';
