-- Combined Phase 4-5 deployment.
-- Run after sql/orchestration/deploy_ingestion_task_graph.sql, using the same
-- deployment role that owns the existing task graph.

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.PHASE45_AUDIT
(
    RUN_ID VARCHAR NOT NULL,
    TASK_NAME VARCHAR NOT NULL,
    STARTED_AT TIMESTAMP_LTZ NOT NULL,
    ENDED_AT TIMESTAMP_LTZ,
    STATUS VARCHAR NOT NULL,
    ROWS_PROCESSED NUMBER(38, 0) NOT NULL DEFAULT 0,
    ERROR_DETAILS VARCHAR,
    PRIMARY KEY (RUN_ID, TASK_NAME)
)
COMMENT = 'Run-level audit for combined Phase 4-5 parsing, DQ, and processing';

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.DQ_RULE_MASTER
(
    RULE_ID VARCHAR NOT NULL,
    DATASET_NAME VARCHAR NOT NULL,
    RULE_NAME VARCHAR NOT NULL,
    RULE_TYPE VARCHAR NOT NULL,
    TARGET_COLUMN VARCHAR,
    ERROR_MESSAGE VARCHAR NOT NULL,
    IS_ENABLED BOOLEAN NOT NULL DEFAULT TRUE,
    CREATED_AT TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (RULE_ID)
)
COMMENT = 'Allowlisted metadata for the reviewed Phase 4-5 DQ rule engine';

MERGE INTO SKYPOINTS_DB.AUDIT.DQ_RULE_MASTER AS target
USING
(
    SELECT column1::VARCHAR AS RULE_ID,
           column2::VARCHAR AS DATASET_NAME,
           column3::VARCHAR AS RULE_NAME,
           column4::VARCHAR AS RULE_TYPE,
           column5::VARCHAR AS TARGET_COLUMN,
           column6::VARCHAR AS ERROR_MESSAGE
    FROM VALUES
        ('MEMBER_ID_NOT_NULL', 'MEMBER', 'Member ID is required',
         'MEMBER_ID_NOT_NULL', 'MEMBER_ID', 'MEMBER_ID must not be empty'),
        ('MEMBER_NAME_NOT_NULL', 'MEMBER', 'Member name is required',
         'MEMBER_NAME_NOT_NULL', 'MEMBER_NAME', 'MEMBER_NAME must not be empty'),
        ('DOB_VALID', 'MEMBER', 'Date of birth is valid',
         'DOB_VALID', 'DOB', 'DOB must be a valid MMDDYYYY date'),
        ('ENROLLMENT_DATE_VALID', 'MEMBER', 'Enrollment date is valid',
         'ENROLLMENT_DATE_VALID', 'ENROLLMENT_DATE',
         'ENROLLMENT_DATE must be a valid YYYYMMDD date'),
        ('COUNTRY_NOT_NULL', 'MEMBER', 'Country is required',
         'COUNTRY_NOT_NULL', 'COUNTRY', 'COUNTRY must not be empty'),
        ('IS_ACTIVE_VALID', 'MEMBER', 'Active indicator is valid',
         'IS_ACTIVE_VALID', 'IS_ACTIVE', 'IS_ACTIVE must be A or I'),
        ('MEMBER_RECORD_TYPE_VALID', 'MEMBER', 'Member record type is valid',
         'MEMBER_RECORD_TYPE_VALID', 'RECORD_TYPE',
         'Business member record type must be D'),
        ('REDEMPTION_ID_NOT_NULL', 'REDEMPTION', 'Redemption ID is required',
         'REDEMPTION_ID_NOT_NULL', 'REDEMPTION_ID',
         'REDEMPTION_ID must not be empty'),
        ('REDEMPTION_MEMBER_ID_NOT_NULL', 'REDEMPTION', 'Member ID is required',
         'MEMBER_ID_NOT_NULL', 'MEMBER_ID', 'MEMBER_ID must not be empty'),
        ('FEED_DATE_VALID', 'REDEMPTION', 'Feed date is valid',
         'FEED_DATE_VALID', 'FEED_DATE', 'FEED_DATE must be a valid YYYYMMDD date'),
        ('POINTS_NON_NEGATIVE', 'REDEMPTION', 'Points are non-negative',
         'POINTS_NON_NEGATIVE', 'POINTS', 'POINTS must be a non-negative number'),
        ('STATUS_VALID', 'REDEMPTION', 'Redemption status is valid',
         'STATUS_VALID', 'STATUS', 'STATUS must be COMPLETED or PENDING'),
        ('MEMBER_EXISTS', 'REDEMPTION', 'Member exists after member processing',
         'MEMBER_EXISTS', 'MEMBER_ID',
         'MEMBER_ID does not identify a valid current member')
) AS source
ON target.RULE_ID = source.RULE_ID
WHEN MATCHED THEN UPDATE SET
    DATASET_NAME = source.DATASET_NAME,
    RULE_NAME = source.RULE_NAME,
    RULE_TYPE = source.RULE_TYPE,
    TARGET_COLUMN = source.TARGET_COLUMN,
    ERROR_MESSAGE = source.ERROR_MESSAGE,
    UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
(
    RULE_ID, DATASET_NAME, RULE_NAME, RULE_TYPE, TARGET_COLUMN,
    ERROR_MESSAGE, IS_ENABLED, CREATED_AT, UPDATED_AT
)
VALUES
(
    source.RULE_ID, source.DATASET_NAME, source.RULE_NAME, source.RULE_TYPE,
    source.TARGET_COLUMN, source.ERROR_MESSAGE, TRUE,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED
(
    RECORD_KEY VARCHAR NOT NULL,
    MEMBER_RECORD_TYPE VARCHAR,
    MEMBER_NAME VARCHAR,
    MEMBER_ID VARCHAR,
    ENROLLMENT_DATE_RAW VARCHAR,
    ENROLLMENT_DATE DATE,
    LAST_FLIGHT_DATE_RAW VARCHAR,
    LAST_FLIGHT_DATE DATE,
    TIER_CODE VARCHAR,
    AGENT_NAME VARCHAR,
    STATE VARCHAR,
    COUNTRY VARCHAR,
    DOB_RAW VARCHAR,
    DOB DATE,
    IS_ACTIVE_RAW VARCHAR,
    POST_CODE VARCHAR,
    SOURCE_FILENAME VARCHAR NOT NULL,
    SOURCE_ROW_NUMBER NUMBER(38, 0) NOT NULL,
    SOURCE_FILE_CONTENT_KEY VARCHAR NOT NULL,
    INGESTED_AT TIMESTAMP_LTZ NOT NULL,
    SOURCE_RECORD VARCHAR NOT NULL,
    PARSED_AT TIMESTAMP_LTZ NOT NULL
)
COMMENT = 'Typed member fields parsed from immutable raw member source lines';

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.STAGING.REDEMPTION_PARSED
(
    RECORD_KEY VARCHAR NOT NULL,
    TRANSACTION_INDEX NUMBER(38, 0) NOT NULL,
    MEMBER_ID VARCHAR,
    FEED_DATE_RAW VARCHAR,
    FEED_DATE DATE,
    REDEMPTION_ID VARCHAR,
    STATUS VARCHAR,
    POINTS_RAW VARCHAR,
    POINTS NUMBER(38, 2),
    SOURCE_FILENAME VARCHAR NOT NULL,
    SOURCE_ROW_NUMBER NUMBER(38, 0) NOT NULL,
    SOURCE_FILE_CONTENT_KEY VARCHAR NOT NULL,
    INGESTED_AT TIMESTAMP_LTZ NOT NULL,
    ORIGINAL_PAYLOAD VARIANT NOT NULL,
    PARSED_AT TIMESTAMP_LTZ NOT NULL
)
COMMENT = 'One typed row per flattened redemption transaction with source lineage';

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.DQ_EXECUTION
(
    RUN_ID VARCHAR NOT NULL,
    DATASET_NAME VARCHAR NOT NULL,
    STARTED_AT TIMESTAMP_LTZ NOT NULL,
    ENDED_AT TIMESTAMP_LTZ,
    STATUS VARCHAR NOT NULL,
    TOTAL_RECORDS NUMBER(38, 0) NOT NULL DEFAULT 0,
    VALID_RECORDS NUMBER(38, 0) NOT NULL DEFAULT 0,
    INVALID_RECORDS NUMBER(38, 0) NOT NULL DEFAULT 0,
    DUPLICATE_COUNT NUMBER(38, 0) NOT NULL DEFAULT 0,
    ERROR_DETAILS VARCHAR,
    PRIMARY KEY (RUN_ID, DATASET_NAME)
)
COMMENT = 'Per-run, per-dataset DQ counts and technical execution status';

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT
(
    RUN_ID VARCHAR NOT NULL,
    DATASET_NAME VARCHAR NOT NULL,
    RECORD_KEY VARCHAR NOT NULL,
    RULE_ID VARCHAR NOT NULL,
    RULE_NAME VARCHAR NOT NULL,
    STATUS VARCHAR NOT NULL,
    EVALUATED_COUNT NUMBER(38, 0) NOT NULL,
    FAILURE_COUNT NUMBER(38, 0) NOT NULL,
    FAILURE_REASON VARCHAR,
    SOURCE_FILENAME VARCHAR NOT NULL,
    SOURCE_ROW_NUMBER NUMBER(38, 0) NOT NULL,
    SOURCE_FILE_CONTENT_KEY VARCHAR NOT NULL,
    EXECUTED_AT TIMESTAMP_LTZ NOT NULL
)
COMMENT = 'Individual rule outcomes per source record, including passing outcomes';

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.STAGING.DQ_QUARANTINE
(
    RUN_ID VARCHAR NOT NULL,
    DATASET_NAME VARCHAR NOT NULL,
    RECORD_KEY VARCHAR NOT NULL,
    SOURCE_FILENAME VARCHAR NOT NULL,
    SOURCE_ROW_NUMBER NUMBER(38, 0) NOT NULL,
    SOURCE_FILE_CONTENT_KEY VARCHAR NOT NULL,
    ORIGINAL_RECORD VARCHAR,
    ORIGINAL_PAYLOAD VARIANT,
    TRANSACTION_INDEX NUMBER(38, 0),
    FAILURE_REASONS VARIANT NOT NULL,
    QUARANTINED_AT TIMESTAMP_LTZ NOT NULL,
    PRIMARY KEY (DATASET_NAME, RECORD_KEY)
)
COMMENT = 'One retained quarantine record per invalid source record or transaction';

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.CORE.MEMBER_CURRENT
(
    MEMBER_ID VARCHAR NOT NULL,
    MEMBER_NAME VARCHAR,
    ENROLLMENT_DATE DATE,
    LAST_FLIGHT_DATE DATE,
    TIER_CODE VARCHAR,
    AGENT_NAME VARCHAR,
    STATE VARCHAR,
    COUNTRY VARCHAR,
    DOB DATE,
    IS_ACTIVE BOOLEAN,
    POST_CODE VARCHAR,
    AGE NUMBER(3, 0),
    STALE_MEMBER BOOLEAN,
    SOURCE_FILENAME VARCHAR NOT NULL,
    SOURCE_ROW_NUMBER NUMBER(38, 0) NOT NULL,
    SOURCE_FILE_CONTENT_KEY VARCHAR NOT NULL,
    INGESTED_AT TIMESTAMP_LTZ NOT NULL,
    SOURCE_RECORD VARCHAR NOT NULL,
    LAST_PROCESSED_RUN_ID VARCHAR NOT NULL,
    UPDATED_AT TIMESTAMP_LTZ NOT NULL,
    PRIMARY KEY (MEMBER_ID)
)
COMMENT = 'Latest valid member profile; arrival timestamp is not a source update timestamp';

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.CORE.MEMBER_HISTORY
(
    MEMBER_ID VARCHAR NOT NULL,
    MEMBER_NAME VARCHAR,
    ENROLLMENT_DATE DATE,
    LAST_FLIGHT_DATE DATE,
    TIER_CODE VARCHAR,
    AGENT_NAME VARCHAR,
    STATE VARCHAR,
    COUNTRY VARCHAR,
    DOB DATE,
    IS_ACTIVE BOOLEAN,
    POST_CODE VARCHAR,
    AGE NUMBER(3, 0),
    STALE_MEMBER BOOLEAN,
    SOURCE_FILENAME VARCHAR NOT NULL,
    SOURCE_ROW_NUMBER NUMBER(38, 0) NOT NULL,
    SOURCE_FILE_CONTENT_KEY VARCHAR NOT NULL,
    INGESTED_AT TIMESTAMP_LTZ NOT NULL,
    SOURCE_RECORD VARCHAR NOT NULL,
    EFFECTIVE_FROM TIMESTAMP_LTZ NOT NULL,
    EFFECTIVE_TO TIMESTAMP_LTZ,
    IS_CURRENT BOOLEAN NOT NULL,
    PRIMARY KEY (MEMBER_ID, EFFECTIVE_FROM)
)
COMMENT = 'Type-2 member history; one current row and a new version only on attribute change';

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.CORE.REDEMPTION_FACT
(
    REDEMPTION_ID VARCHAR NOT NULL,
    MEMBER_ID VARCHAR NOT NULL,
    FEED_DATE DATE NOT NULL,
    STATUS VARCHAR NOT NULL,
    POINTS NUMBER(38, 2) NOT NULL,
    SOURCE_FILENAME VARCHAR NOT NULL,
    SOURCE_ROW_NUMBER NUMBER(38, 0) NOT NULL,
    SOURCE_FILE_CONTENT_KEY VARCHAR NOT NULL,
    TRANSACTION_INDEX NUMBER(38, 0) NOT NULL,
    INGESTED_AT TIMESTAMP_LTZ NOT NULL,
    ORIGINAL_PAYLOAD VARIANT NOT NULL,
    LAST_PROCESSED_RUN_ID VARCHAR NOT NULL,
    UPDATED_AT TIMESTAMP_LTZ NOT NULL,
    PRIMARY KEY (REDEMPTION_ID)
)
COMMENT = 'Validated and deduplicated partner redemption transactions with raw lineage';

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.STAGING.SP_PARSE_AND_NORMALIZE()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id VARCHAR;
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_rows_processed NUMBER(38, 0) DEFAULT 0;
BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')
      INTO :v_run_id;

    MERGE INTO SKYPOINTS_DB.AUDIT.PHASE45_AUDIT AS target
    USING (SELECT :v_run_id AS RUN_ID, 'TASK_PARSE_AND_NORMALIZE' AS TASK_NAME) AS source
       ON target.RUN_ID = source.RUN_ID AND target.TASK_NAME = source.TASK_NAME
    WHEN MATCHED THEN UPDATE SET
        STARTED_AT = :v_started_at, ENDED_AT = NULL, STATUS = 'STARTED',
        ROWS_PROCESSED = 0, ERROR_DETAILS = NULL
    WHEN NOT MATCHED THEN INSERT
        (RUN_ID, TASK_NAME, STARTED_AT, STATUS, ROWS_PROCESSED)
    VALUES
        (source.RUN_ID, source.TASK_NAME, :v_started_at, 'STARTED', 0);

    MERGE INTO SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED AS target
    USING
    (
        SELECT
            SHA2(TO_JSON(ARRAY_CONSTRUCT(
                SOURCE_FILENAME, SOURCE_ROW_NUMBER, SOURCE_FILE_CONTENT_KEY
            )), 256) AS RECORD_KEY,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 2)), '') AS MEMBER_RECORD_TYPE,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 3)), '') AS MEMBER_NAME,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 4)), '') AS MEMBER_ID,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 5)), '') AS ENROLLMENT_DATE_RAW,
            TRY_TO_DATE(NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 5)), ''),
                        'YYYYMMDD') AS ENROLLMENT_DATE,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 6)), '') AS LAST_FLIGHT_DATE_RAW,
            TRY_TO_DATE(NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 6)), ''),
                        'YYYYMMDD') AS LAST_FLIGHT_DATE,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 7)), '') AS TIER_CODE,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 8)), '') AS AGENT_NAME,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 9)), '') AS STATE,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 10)), '') AS COUNTRY,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 11)), '') AS DOB_RAW,
            TRY_TO_DATE(NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 11)), ''),
                        'MMDDYYYY') AS DOB,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 12)), '') AS IS_ACTIVE_RAW,
            NULLIF(TRIM(SPLIT_PART(SOURCE_RECORD, '|', 13)), '') AS POST_CODE,
            SOURCE_FILENAME, SOURCE_ROW_NUMBER, SOURCE_FILE_CONTENT_KEY,
            INGESTED_AT, SOURCE_RECORD
        FROM SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW
        QUALIFY ROW_NUMBER() OVER
        (
            PARTITION BY SOURCE_FILENAME, SOURCE_ROW_NUMBER, SOURCE_FILE_CONTENT_KEY
            ORDER BY INGESTED_AT DESC, SOURCE_RECORD DESC
        ) = 1
    ) AS source
       ON target.RECORD_KEY = source.RECORD_KEY
    WHEN MATCHED THEN UPDATE SET
        MEMBER_RECORD_TYPE = source.MEMBER_RECORD_TYPE,
        MEMBER_NAME = source.MEMBER_NAME,
        MEMBER_ID = source.MEMBER_ID,
        ENROLLMENT_DATE_RAW = source.ENROLLMENT_DATE_RAW,
        ENROLLMENT_DATE = source.ENROLLMENT_DATE,
        LAST_FLIGHT_DATE_RAW = source.LAST_FLIGHT_DATE_RAW,
        LAST_FLIGHT_DATE = source.LAST_FLIGHT_DATE,
        TIER_CODE = source.TIER_CODE,
        AGENT_NAME = source.AGENT_NAME,
        STATE = source.STATE,
        COUNTRY = source.COUNTRY,
        DOB_RAW = source.DOB_RAW,
        DOB = source.DOB,
        IS_ACTIVE_RAW = source.IS_ACTIVE_RAW,
        POST_CODE = source.POST_CODE,
        SOURCE_FILENAME = source.SOURCE_FILENAME,
        SOURCE_ROW_NUMBER = source.SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY = source.SOURCE_FILE_CONTENT_KEY,
        INGESTED_AT = source.INGESTED_AT,
        SOURCE_RECORD = source.SOURCE_RECORD,
        PARSED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
    (
        RECORD_KEY, MEMBER_RECORD_TYPE, MEMBER_NAME, MEMBER_ID,
        ENROLLMENT_DATE_RAW, ENROLLMENT_DATE, LAST_FLIGHT_DATE_RAW,
        LAST_FLIGHT_DATE, TIER_CODE, AGENT_NAME, STATE, COUNTRY,
        DOB_RAW, DOB, IS_ACTIVE_RAW, POST_CODE, SOURCE_FILENAME,
        SOURCE_ROW_NUMBER, SOURCE_FILE_CONTENT_KEY, INGESTED_AT,
        SOURCE_RECORD, PARSED_AT
    )
    VALUES
    (
        source.RECORD_KEY, source.MEMBER_RECORD_TYPE, source.MEMBER_NAME,
        source.MEMBER_ID, source.ENROLLMENT_DATE_RAW, source.ENROLLMENT_DATE,
        source.LAST_FLIGHT_DATE_RAW, source.LAST_FLIGHT_DATE, source.TIER_CODE,
        source.AGENT_NAME, source.STATE, source.COUNTRY, source.DOB_RAW,
        source.DOB, source.IS_ACTIVE_RAW, source.POST_CODE,
        source.SOURCE_FILENAME, source.SOURCE_ROW_NUMBER,
        source.SOURCE_FILE_CONTENT_KEY, source.INGESTED_AT,
        source.SOURCE_RECORD, CURRENT_TIMESTAMP()
    );

    MERGE INTO SKYPOINTS_DB.STAGING.REDEMPTION_PARSED AS target
    USING
    (
        SELECT
            SHA2(TO_JSON(ARRAY_CONSTRUCT(
                raw.SOURCE_FILENAME, raw.SOURCE_ROW_NUMBER,
                raw.SOURCE_FILE_CONTENT_KEY, flattened.INDEX
            )), 256) AS RECORD_KEY,
            flattened.INDEX::NUMBER(38, 0) AS TRANSACTION_INDEX,
            NULLIF(TRIM(raw.PAYLOAD:member_id::VARCHAR), '') AS MEMBER_ID,
            NULLIF(TRIM(raw.PAYLOAD:feed_date::VARCHAR), '') AS FEED_DATE_RAW,
            TRY_TO_DATE(NULLIF(TRIM(raw.PAYLOAD:feed_date::VARCHAR), ''),
                        'YYYYMMDD') AS FEED_DATE,
            NULLIF(TRIM(flattened.VALUE:redemption_id::VARCHAR), '') AS REDEMPTION_ID,
            NULLIF(TRIM(flattened.VALUE:status::VARCHAR), '') AS STATUS,
            NULLIF(TRIM(flattened.VALUE:points::VARCHAR), '') AS POINTS_RAW,
            TRY_TO_DECIMAL(flattened.VALUE:points::VARCHAR, 38, 2) AS POINTS,
            raw.SOURCE_FILENAME, raw.SOURCE_ROW_NUMBER,
            raw.SOURCE_FILE_CONTENT_KEY, raw.INGESTED_AT,
            raw.PAYLOAD AS ORIGINAL_PAYLOAD
        FROM SKYPOINTS_DB.RAW.REDEMPTION_RAW AS raw,
             LATERAL FLATTEN(INPUT => raw.PAYLOAD:redemptions) AS flattened
        QUALIFY ROW_NUMBER() OVER
        (
            PARTITION BY raw.SOURCE_FILENAME, raw.SOURCE_ROW_NUMBER,
                         raw.SOURCE_FILE_CONTENT_KEY, flattened.INDEX
            ORDER BY raw.INGESTED_AT DESC, TO_JSON(raw.PAYLOAD) DESC
        ) = 1
    ) AS source
       ON target.RECORD_KEY = source.RECORD_KEY
    WHEN MATCHED THEN UPDATE SET
        TRANSACTION_INDEX = source.TRANSACTION_INDEX,
        MEMBER_ID = source.MEMBER_ID,
        FEED_DATE_RAW = source.FEED_DATE_RAW,
        FEED_DATE = source.FEED_DATE,
        REDEMPTION_ID = source.REDEMPTION_ID,
        STATUS = source.STATUS,
        POINTS_RAW = source.POINTS_RAW,
        POINTS = source.POINTS,
        SOURCE_FILENAME = source.SOURCE_FILENAME,
        SOURCE_ROW_NUMBER = source.SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY = source.SOURCE_FILE_CONTENT_KEY,
        INGESTED_AT = source.INGESTED_AT,
        ORIGINAL_PAYLOAD = source.ORIGINAL_PAYLOAD,
        PARSED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
    (
        RECORD_KEY, TRANSACTION_INDEX, MEMBER_ID, FEED_DATE_RAW, FEED_DATE,
        REDEMPTION_ID, STATUS, POINTS_RAW, POINTS, SOURCE_FILENAME,
        SOURCE_ROW_NUMBER, SOURCE_FILE_CONTENT_KEY, INGESTED_AT,
        ORIGINAL_PAYLOAD, PARSED_AT
    )
    VALUES
    (
        source.RECORD_KEY, source.TRANSACTION_INDEX, source.MEMBER_ID,
        source.FEED_DATE_RAW, source.FEED_DATE, source.REDEMPTION_ID,
        source.STATUS, source.POINTS_RAW, source.POINTS, source.SOURCE_FILENAME,
        source.SOURCE_ROW_NUMBER, source.SOURCE_FILE_CONTENT_KEY,
        source.INGESTED_AT, source.ORIGINAL_PAYLOAD, CURRENT_TIMESTAMP()
    );

    SELECT
        (SELECT COUNT(*) FROM SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED)
        + (SELECT COUNT(*) FROM SKYPOINTS_DB.STAGING.REDEMPTION_PARSED)
      INTO :v_rows_processed;

    UPDATE SKYPOINTS_DB.AUDIT.PHASE45_AUDIT
       SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'SUCCEEDED',
           ROWS_PROCESSED = :v_rows_processed
     WHERE RUN_ID = :v_run_id AND TASK_NAME = 'TASK_PARSE_AND_NORMALIZE';

    RETURN OBJECT_CONSTRUCT('run_id', v_run_id, 'rows_processed', v_rows_processed);
EXCEPTION
    WHEN OTHER THEN
        UPDATE SKYPOINTS_DB.AUDIT.PHASE45_AUDIT
           SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'FAILED',
               ERROR_DETAILS = :SQLERRM
         WHERE RUN_ID = :v_run_id AND TASK_NAME = 'TASK_PARSE_AND_NORMALIZE';
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.STAGING.SP_RUN_DQ_VALIDATION()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    e_unsupported_rule EXCEPTION
        (-20002, 'DQ_RULE_MASTER contains an enabled rule type not supported by the reviewed rule engine');
    v_run_id VARCHAR;
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_rows_processed NUMBER(38, 0) DEFAULT 0;
    v_unsupported_rules NUMBER(38, 0) DEFAULT 0;
    v_member_total NUMBER(38, 0) DEFAULT 0;
    v_member_valid NUMBER(38, 0) DEFAULT 0;
    v_member_invalid NUMBER(38, 0) DEFAULT 0;
    v_member_duplicates NUMBER(38, 0) DEFAULT 0;
    v_redemption_total NUMBER(38, 0) DEFAULT 0;
    v_redemption_valid NUMBER(38, 0) DEFAULT 0;
    v_redemption_invalid NUMBER(38, 0) DEFAULT 0;
    v_redemption_duplicates NUMBER(38, 0) DEFAULT 0;
BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')
      INTO :v_run_id;

    MERGE INTO SKYPOINTS_DB.AUDIT.PHASE45_AUDIT AS target
    USING (SELECT :v_run_id AS RUN_ID, 'TASK_DQ_VALIDATION' AS TASK_NAME) AS source
       ON target.RUN_ID = source.RUN_ID AND target.TASK_NAME = source.TASK_NAME
    WHEN MATCHED THEN UPDATE SET
        STARTED_AT = :v_started_at, ENDED_AT = NULL, STATUS = 'STARTED',
        ROWS_PROCESSED = 0, ERROR_DETAILS = NULL
    WHEN NOT MATCHED THEN INSERT
        (RUN_ID, TASK_NAME, STARTED_AT, STATUS, ROWS_PROCESSED)
    VALUES
        (source.RUN_ID, source.TASK_NAME, :v_started_at, 'STARTED', 0);

    MERGE INTO SKYPOINTS_DB.AUDIT.DQ_EXECUTION AS target
    USING
    (
        SELECT :v_run_id AS RUN_ID, dataset_name AS DATASET_NAME
        FROM VALUES ('MEMBER'), ('REDEMPTION') AS datasets(dataset_name)
    ) AS source
       ON target.RUN_ID = source.RUN_ID AND target.DATASET_NAME = source.DATASET_NAME
    WHEN MATCHED THEN UPDATE SET
        STARTED_AT = :v_started_at, ENDED_AT = NULL, STATUS = 'RUNNING',
        TOTAL_RECORDS = 0, VALID_RECORDS = 0, INVALID_RECORDS = 0,
        DUPLICATE_COUNT = 0, ERROR_DETAILS = NULL
    WHEN NOT MATCHED THEN INSERT
        (RUN_ID, DATASET_NAME, STARTED_AT, STATUS)
    VALUES
        (source.RUN_ID, source.DATASET_NAME, :v_started_at, 'RUNNING');

    SELECT COUNT(*)
      INTO :v_unsupported_rules
      FROM SKYPOINTS_DB.AUDIT.DQ_RULE_MASTER
     WHERE IS_ENABLED
       AND (
            (DATASET_NAME = 'MEMBER' AND RULE_TYPE NOT IN
             ('MEMBER_ID_NOT_NULL', 'MEMBER_NAME_NOT_NULL', 'DOB_VALID',
              'ENROLLMENT_DATE_VALID', 'COUNTRY_NOT_NULL', 'IS_ACTIVE_VALID',
              'MEMBER_RECORD_TYPE_VALID'))
            OR
            (DATASET_NAME = 'REDEMPTION' AND RULE_TYPE NOT IN
             ('REDEMPTION_ID_NOT_NULL', 'MEMBER_ID_NOT_NULL', 'FEED_DATE_VALID',
              'POINTS_NON_NEGATIVE', 'STATUS_VALID', 'MEMBER_EXISTS'))
            OR DATASET_NAME NOT IN ('MEMBER', 'REDEMPTION')
       );
    IF (v_unsupported_rules > 0) THEN
        RAISE e_unsupported_rule;
    END IF;

    MERGE INTO SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS target
    USING
    (
        SELECT
            :v_run_id AS RUN_ID,
            'MEMBER' AS DATASET_NAME,
            member.RECORD_KEY,
            rule.RULE_ID,
            rule.RULE_NAME,
            IFF(
                CASE rule.RULE_TYPE
                    WHEN 'MEMBER_ID_NOT_NULL' THEN
                        NULLIF(TRIM(member.MEMBER_ID), '') IS NOT NULL
                    WHEN 'MEMBER_NAME_NOT_NULL' THEN
                        NULLIF(TRIM(member.MEMBER_NAME), '') IS NOT NULL
                    WHEN 'DOB_VALID' THEN
                        member.DOB_RAW IS NOT NULL AND member.DOB IS NOT NULL
                    WHEN 'ENROLLMENT_DATE_VALID' THEN
                        member.ENROLLMENT_DATE_RAW IS NOT NULL
                        AND member.ENROLLMENT_DATE IS NOT NULL
                    WHEN 'COUNTRY_NOT_NULL' THEN
                        NULLIF(TRIM(member.COUNTRY), '') IS NOT NULL
                    WHEN 'IS_ACTIVE_VALID' THEN
                        UPPER(TRIM(member.IS_ACTIVE_RAW)) IN ('A', 'I')
                    WHEN 'MEMBER_RECORD_TYPE_VALID' THEN
                        member.MEMBER_RECORD_TYPE = 'D'
                    ELSE FALSE
                END,
                'PASSED', 'FAILED'
            ) AS STATUS,
            IFF(
                CASE rule.RULE_TYPE
                    WHEN 'MEMBER_ID_NOT_NULL' THEN
                        NULLIF(TRIM(member.MEMBER_ID), '') IS NOT NULL
                    WHEN 'MEMBER_NAME_NOT_NULL' THEN
                        NULLIF(TRIM(member.MEMBER_NAME), '') IS NOT NULL
                    WHEN 'DOB_VALID' THEN
                        member.DOB_RAW IS NOT NULL AND member.DOB IS NOT NULL
                    WHEN 'ENROLLMENT_DATE_VALID' THEN
                        member.ENROLLMENT_DATE_RAW IS NOT NULL
                        AND member.ENROLLMENT_DATE IS NOT NULL
                    WHEN 'COUNTRY_NOT_NULL' THEN
                        NULLIF(TRIM(member.COUNTRY), '') IS NOT NULL
                    WHEN 'IS_ACTIVE_VALID' THEN
                        UPPER(TRIM(member.IS_ACTIVE_RAW)) IN ('A', 'I')
                    WHEN 'MEMBER_RECORD_TYPE_VALID' THEN
                        member.MEMBER_RECORD_TYPE = 'D'
                    ELSE FALSE
                END,
                NULL, rule.ERROR_MESSAGE
            ) AS FAILURE_REASON,
            member.SOURCE_FILENAME, member.SOURCE_ROW_NUMBER,
            member.SOURCE_FILE_CONTENT_KEY
        FROM SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED AS member
        CROSS JOIN SKYPOINTS_DB.AUDIT.DQ_RULE_MASTER AS rule
        WHERE rule.DATASET_NAME = 'MEMBER'
          AND rule.IS_ENABLED
          AND COALESCE(member.MEMBER_RECORD_TYPE, '') <> 'H'
    ) AS source
       ON target.RUN_ID = source.RUN_ID
      AND target.DATASET_NAME = source.DATASET_NAME
      AND target.RECORD_KEY = source.RECORD_KEY
      AND target.RULE_ID = source.RULE_ID
    WHEN MATCHED THEN UPDATE SET
        RULE_NAME = source.RULE_NAME,
        STATUS = source.STATUS,
        EVALUATED_COUNT = 1,
        FAILURE_COUNT = IFF(source.STATUS = 'FAILED', 1, 0),
        FAILURE_REASON = source.FAILURE_REASON,
        SOURCE_FILENAME = source.SOURCE_FILENAME,
        SOURCE_ROW_NUMBER = source.SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY = source.SOURCE_FILE_CONTENT_KEY,
        EXECUTED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
    (
        RUN_ID, DATASET_NAME, RECORD_KEY, RULE_ID, RULE_NAME, STATUS,
        EVALUATED_COUNT, FAILURE_COUNT, FAILURE_REASON, SOURCE_FILENAME,
        SOURCE_ROW_NUMBER, SOURCE_FILE_CONTENT_KEY, EXECUTED_AT
    )
    VALUES
    (
        source.RUN_ID, source.DATASET_NAME, source.RECORD_KEY, source.RULE_ID,
        source.RULE_NAME, source.STATUS, 1,
        IFF(source.STATUS = 'FAILED', 1, 0), source.FAILURE_REASON,
        source.SOURCE_FILENAME, source.SOURCE_ROW_NUMBER,
        source.SOURCE_FILE_CONTENT_KEY, CURRENT_TIMESTAMP()
    );

    MERGE INTO SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS target
    USING
    (
        SELECT
            :v_run_id AS RUN_ID,
            'REDEMPTION' AS DATASET_NAME,
            redemption.RECORD_KEY,
            rule.RULE_ID,
            rule.RULE_NAME,
            IFF(
                CASE rule.RULE_TYPE
                    WHEN 'REDEMPTION_ID_NOT_NULL' THEN
                        NULLIF(TRIM(redemption.REDEMPTION_ID), '') IS NOT NULL
                    WHEN 'MEMBER_ID_NOT_NULL' THEN
                        NULLIF(TRIM(redemption.MEMBER_ID), '') IS NOT NULL
                    WHEN 'FEED_DATE_VALID' THEN
                        redemption.FEED_DATE_RAW IS NOT NULL
                        AND redemption.FEED_DATE IS NOT NULL
                    WHEN 'POINTS_NON_NEGATIVE' THEN
                        redemption.POINTS IS NOT NULL AND redemption.POINTS >= 0
                    WHEN 'STATUS_VALID' THEN
                        UPPER(TRIM(redemption.STATUS)) IN ('COMPLETED', 'PENDING')
                    WHEN 'MEMBER_EXISTS' THEN
                        EXISTS
                        (
                            SELECT 1
                            FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT AS current_member
                            WHERE current_member.MEMBER_ID = redemption.MEMBER_ID
                        )
                        OR EXISTS
                        (
                            SELECT 1
                            FROM SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED AS incoming
                            WHERE incoming.MEMBER_RECORD_TYPE = 'D'
                              AND incoming.MEMBER_ID = redemption.MEMBER_ID
                              AND NOT EXISTS
                              (
                                  SELECT 1
                                  FROM SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS member_rule
                                  WHERE member_rule.RUN_ID = :v_run_id
                                    AND member_rule.DATASET_NAME = 'MEMBER'
                                    AND member_rule.RECORD_KEY = incoming.RECORD_KEY
                                    AND member_rule.STATUS = 'FAILED'
                              )
                        )
                    ELSE FALSE
                END,
                'PASSED', 'FAILED'
            ) AS STATUS,
            IFF(
                CASE rule.RULE_TYPE
                    WHEN 'REDEMPTION_ID_NOT_NULL' THEN
                        NULLIF(TRIM(redemption.REDEMPTION_ID), '') IS NOT NULL
                    WHEN 'MEMBER_ID_NOT_NULL' THEN
                        NULLIF(TRIM(redemption.MEMBER_ID), '') IS NOT NULL
                    WHEN 'FEED_DATE_VALID' THEN
                        redemption.FEED_DATE_RAW IS NOT NULL
                        AND redemption.FEED_DATE IS NOT NULL
                    WHEN 'POINTS_NON_NEGATIVE' THEN
                        redemption.POINTS IS NOT NULL AND redemption.POINTS >= 0
                    WHEN 'STATUS_VALID' THEN
                        UPPER(TRIM(redemption.STATUS)) IN ('COMPLETED', 'PENDING')
                    WHEN 'MEMBER_EXISTS' THEN
                        EXISTS
                        (
                            SELECT 1
                            FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT AS current_member
                            WHERE current_member.MEMBER_ID = redemption.MEMBER_ID
                        )
                        OR EXISTS
                        (
                            SELECT 1
                            FROM SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED AS incoming
                            WHERE incoming.MEMBER_RECORD_TYPE = 'D'
                              AND incoming.MEMBER_ID = redemption.MEMBER_ID
                              AND NOT EXISTS
                              (
                                  SELECT 1
                                  FROM SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS member_rule
                                  WHERE member_rule.RUN_ID = :v_run_id
                                    AND member_rule.DATASET_NAME = 'MEMBER'
                                    AND member_rule.RECORD_KEY = incoming.RECORD_KEY
                                    AND member_rule.STATUS = 'FAILED'
                              )
                        )
                    ELSE FALSE
                END,
                NULL, rule.ERROR_MESSAGE
            ) AS FAILURE_REASON,
            redemption.SOURCE_FILENAME, redemption.SOURCE_ROW_NUMBER,
            redemption.SOURCE_FILE_CONTENT_KEY
        FROM SKYPOINTS_DB.STAGING.REDEMPTION_PARSED AS redemption
        CROSS JOIN SKYPOINTS_DB.AUDIT.DQ_RULE_MASTER AS rule
        WHERE rule.DATASET_NAME = 'REDEMPTION'
          AND rule.IS_ENABLED
    ) AS source
       ON target.RUN_ID = source.RUN_ID
      AND target.DATASET_NAME = source.DATASET_NAME
      AND target.RECORD_KEY = source.RECORD_KEY
      AND target.RULE_ID = source.RULE_ID
    WHEN MATCHED THEN UPDATE SET
        RULE_NAME = source.RULE_NAME,
        STATUS = source.STATUS,
        EVALUATED_COUNT = 1,
        FAILURE_COUNT = IFF(source.STATUS = 'FAILED', 1, 0),
        FAILURE_REASON = source.FAILURE_REASON,
        SOURCE_FILENAME = source.SOURCE_FILENAME,
        SOURCE_ROW_NUMBER = source.SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY = source.SOURCE_FILE_CONTENT_KEY,
        EXECUTED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
    (
        RUN_ID, DATASET_NAME, RECORD_KEY, RULE_ID, RULE_NAME, STATUS,
        EVALUATED_COUNT, FAILURE_COUNT, FAILURE_REASON, SOURCE_FILENAME,
        SOURCE_ROW_NUMBER, SOURCE_FILE_CONTENT_KEY, EXECUTED_AT
    )
    VALUES
    (
        source.RUN_ID, source.DATASET_NAME, source.RECORD_KEY, source.RULE_ID,
        source.RULE_NAME, source.STATUS, 1,
        IFF(source.STATUS = 'FAILED', 1, 0), source.FAILURE_REASON,
        source.SOURCE_FILENAME, source.SOURCE_ROW_NUMBER,
        source.SOURCE_FILE_CONTENT_KEY, CURRENT_TIMESTAMP()
    );

    MERGE INTO SKYPOINTS_DB.STAGING.DQ_QUARANTINE AS target
    USING
    (
        SELECT
            :v_run_id AS RUN_ID, 'MEMBER' AS DATASET_NAME, member.RECORD_KEY,
            member.SOURCE_FILENAME, member.SOURCE_ROW_NUMBER,
            member.SOURCE_FILE_CONTENT_KEY, member.SOURCE_RECORD AS ORIGINAL_RECORD,
            NULL::VARIANT AS ORIGINAL_PAYLOAD, NULL::NUMBER(38, 0) AS TRANSACTION_INDEX,
            ARRAY_AGG(OBJECT_CONSTRUCT(
                'rule_id', result.RULE_ID,
                'rule_name', result.RULE_NAME,
                'message', result.FAILURE_REASON
            )) WITHIN GROUP (ORDER BY result.RULE_ID) AS FAILURE_REASONS
        FROM SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED AS member
        JOIN SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS result
          ON result.RECORD_KEY = member.RECORD_KEY
         AND result.RUN_ID = :v_run_id
         AND result.DATASET_NAME = 'MEMBER'
         AND result.STATUS = 'FAILED'
        GROUP BY member.RECORD_KEY, member.SOURCE_FILENAME,
                 member.SOURCE_ROW_NUMBER, member.SOURCE_FILE_CONTENT_KEY,
                 member.SOURCE_RECORD
    ) AS source
       ON target.DATASET_NAME = source.DATASET_NAME
      AND target.RECORD_KEY = source.RECORD_KEY
    WHEN MATCHED THEN UPDATE SET
        FAILURE_REASONS = source.FAILURE_REASONS
    WHEN NOT MATCHED THEN INSERT
    (
        RUN_ID, DATASET_NAME, RECORD_KEY, SOURCE_FILENAME, SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY, ORIGINAL_RECORD, ORIGINAL_PAYLOAD,
        TRANSACTION_INDEX, FAILURE_REASONS, QUARANTINED_AT
    )
    VALUES
    (
        source.RUN_ID, source.DATASET_NAME, source.RECORD_KEY,
        source.SOURCE_FILENAME, source.SOURCE_ROW_NUMBER,
        source.SOURCE_FILE_CONTENT_KEY, source.ORIGINAL_RECORD,
        source.ORIGINAL_PAYLOAD, source.TRANSACTION_INDEX,
        source.FAILURE_REASONS, CURRENT_TIMESTAMP()
    );

    MERGE INTO SKYPOINTS_DB.STAGING.DQ_QUARANTINE AS target
    USING
    (
        SELECT
            :v_run_id AS RUN_ID, 'REDEMPTION' AS DATASET_NAME,
            redemption.RECORD_KEY, redemption.SOURCE_FILENAME,
            redemption.SOURCE_ROW_NUMBER, redemption.SOURCE_FILE_CONTENT_KEY,
            NULL::VARCHAR AS ORIGINAL_RECORD,
            redemption.ORIGINAL_PAYLOAD,
            redemption.TRANSACTION_INDEX,
            ARRAY_AGG(OBJECT_CONSTRUCT(
                'rule_id', result.RULE_ID,
                'rule_name', result.RULE_NAME,
                'message', result.FAILURE_REASON
            )) WITHIN GROUP (ORDER BY result.RULE_ID) AS FAILURE_REASONS
        FROM SKYPOINTS_DB.STAGING.REDEMPTION_PARSED AS redemption
        JOIN SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS result
          ON result.RECORD_KEY = redemption.RECORD_KEY
         AND result.RUN_ID = :v_run_id
         AND result.DATASET_NAME = 'REDEMPTION'
         AND result.STATUS = 'FAILED'
        GROUP BY redemption.RECORD_KEY, redemption.SOURCE_FILENAME,
                 redemption.SOURCE_ROW_NUMBER, redemption.SOURCE_FILE_CONTENT_KEY,
                 redemption.ORIGINAL_PAYLOAD, redemption.TRANSACTION_INDEX
    ) AS source
       ON target.DATASET_NAME = source.DATASET_NAME
      AND target.RECORD_KEY = source.RECORD_KEY
    WHEN MATCHED THEN UPDATE SET
        FAILURE_REASONS = source.FAILURE_REASONS
    WHEN NOT MATCHED THEN INSERT
    (
        RUN_ID, DATASET_NAME, RECORD_KEY, SOURCE_FILENAME, SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY, ORIGINAL_RECORD, ORIGINAL_PAYLOAD,
        TRANSACTION_INDEX, FAILURE_REASONS, QUARANTINED_AT
    )
    VALUES
    (
        source.RUN_ID, source.DATASET_NAME, source.RECORD_KEY,
        source.SOURCE_FILENAME, source.SOURCE_ROW_NUMBER,
        source.SOURCE_FILE_CONTENT_KEY, source.ORIGINAL_RECORD,
        source.ORIGINAL_PAYLOAD, source.TRANSACTION_INDEX,
        source.FAILURE_REASONS, CURRENT_TIMESTAMP()
    );

    SELECT
        COUNT(*), COALESCE(COUNT_IF(failure_count = 0), 0),
        COALESCE(COUNT_IF(failure_count > 0), 0)
      INTO :v_member_total, :v_member_valid, :v_member_invalid
      FROM
      (
          SELECT member.RECORD_KEY,
                 COALESCE(COUNT_IF(result.STATUS = 'FAILED'), 0) AS failure_count
          FROM SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED AS member
          LEFT JOIN SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS result
            ON result.RUN_ID = :v_run_id
           AND result.DATASET_NAME = 'MEMBER'
           AND result.RECORD_KEY = member.RECORD_KEY
          WHERE COALESCE(member.MEMBER_RECORD_TYPE, '') <> 'H'
          GROUP BY member.RECORD_KEY
      ) AS member_failures;

    SELECT COALESCE(SUM(duplicate_rows), 0)
      INTO :v_member_duplicates
      FROM
      (
          SELECT GREATEST(COUNT(*) - 1, 0) AS duplicate_rows
          FROM SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED
          WHERE MEMBER_RECORD_TYPE = 'D' AND MEMBER_ID IS NOT NULL
          GROUP BY MEMBER_ID
      ) AS member_duplicate_groups;

    MERGE INTO SKYPOINTS_DB.AUDIT.DQ_EXECUTION AS target
    USING
    (
        SELECT :v_run_id AS RUN_ID, 'MEMBER' AS DATASET_NAME
    ) AS source
       ON target.RUN_ID = source.RUN_ID AND target.DATASET_NAME = source.DATASET_NAME
    WHEN MATCHED THEN UPDATE SET
        ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'SUCCEEDED',
        TOTAL_RECORDS = :v_member_total, VALID_RECORDS = :v_member_valid,
        INVALID_RECORDS = :v_member_invalid, DUPLICATE_COUNT = :v_member_duplicates,
        ERROR_DETAILS = NULL;

    SELECT
        COUNT(*), COALESCE(COUNT_IF(failure_count = 0), 0),
        COALESCE(COUNT_IF(failure_count > 0), 0)
      INTO :v_redemption_total, :v_redemption_valid, :v_redemption_invalid
      FROM
      (
          SELECT redemption.RECORD_KEY,
                 COALESCE(COUNT_IF(result.STATUS = 'FAILED'), 0) AS failure_count
          FROM SKYPOINTS_DB.STAGING.REDEMPTION_PARSED AS redemption
          LEFT JOIN SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS result
            ON result.RUN_ID = :v_run_id
           AND result.DATASET_NAME = 'REDEMPTION'
           AND result.RECORD_KEY = redemption.RECORD_KEY
          GROUP BY redemption.RECORD_KEY
      ) AS redemption_failures;

    SELECT COALESCE(SUM(duplicate_rows), 0)
      INTO :v_redemption_duplicates
      FROM
      (
          SELECT GREATEST(COUNT(*) - 1, 0) AS duplicate_rows
          FROM SKYPOINTS_DB.STAGING.REDEMPTION_PARSED
          WHERE REDEMPTION_ID IS NOT NULL
          GROUP BY REDEMPTION_ID
      ) AS redemption_duplicate_groups;

    MERGE INTO SKYPOINTS_DB.AUDIT.DQ_EXECUTION AS target
    USING
    (
        SELECT :v_run_id AS RUN_ID, 'REDEMPTION' AS DATASET_NAME
    ) AS source
       ON target.RUN_ID = source.RUN_ID AND target.DATASET_NAME = source.DATASET_NAME
    WHEN MATCHED THEN UPDATE SET
        ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'SUCCEEDED',
        TOTAL_RECORDS = :v_redemption_total, VALID_RECORDS = :v_redemption_valid,
        INVALID_RECORDS = :v_redemption_invalid,
        DUPLICATE_COUNT = :v_redemption_duplicates, ERROR_DETAILS = NULL;

    v_rows_processed := v_member_total + v_redemption_total;
    UPDATE SKYPOINTS_DB.AUDIT.PHASE45_AUDIT
       SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'SUCCEEDED',
           ROWS_PROCESSED = :v_rows_processed
     WHERE RUN_ID = :v_run_id AND TASK_NAME = 'TASK_DQ_VALIDATION';

    RETURN OBJECT_CONSTRUCT(
        'run_id', v_run_id,
        'member_invalid_records', v_member_invalid,
        'redemption_invalid_records', v_redemption_invalid
    );
EXCEPTION
    WHEN OTHER THEN
        UPDATE SKYPOINTS_DB.AUDIT.DQ_EXECUTION
           SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'FAILED',
               ERROR_DETAILS = :SQLERRM
         WHERE RUN_ID = :v_run_id AND STATUS = 'RUNNING';
        UPDATE SKYPOINTS_DB.AUDIT.PHASE45_AUDIT
           SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'FAILED',
               ERROR_DETAILS = :SQLERRM
         WHERE RUN_ID = :v_run_id AND TASK_NAME = 'TASK_DQ_VALIDATION';
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.CORE.SP_PROCESS_MEMBERS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id VARCHAR;
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_processed_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_rows_processed NUMBER(38, 0) DEFAULT 0;
    v_transaction_started BOOLEAN DEFAULT FALSE;
BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')
      INTO :v_run_id;

    MERGE INTO SKYPOINTS_DB.AUDIT.PHASE45_AUDIT AS target
    USING (SELECT :v_run_id AS RUN_ID, 'TASK_MEMBER_PROCESSING' AS TASK_NAME) AS source
       ON target.RUN_ID = source.RUN_ID AND target.TASK_NAME = source.TASK_NAME
    WHEN MATCHED THEN UPDATE SET
        STARTED_AT = :v_started_at, ENDED_AT = NULL, STATUS = 'STARTED',
        ROWS_PROCESSED = 0, ERROR_DETAILS = NULL
    WHEN NOT MATCHED THEN INSERT
        (RUN_ID, TASK_NAME, STARTED_AT, STATUS, ROWS_PROCESSED)
    VALUES
        (source.RUN_ID, source.TASK_NAME, :v_started_at, 'STARTED', 0);

    CREATE OR REPLACE TEMPORARY TABLE SKYPOINTS_DB.CORE.MEMBER_WINNERS AS
    SELECT
        member.MEMBER_ID, member.MEMBER_NAME, member.ENROLLMENT_DATE,
        member.LAST_FLIGHT_DATE, member.TIER_CODE, member.AGENT_NAME,
        member.STATE, member.COUNTRY, member.DOB,
        IFF(UPPER(member.IS_ACTIVE_RAW) = 'A', TRUE, FALSE) AS IS_ACTIVE,
        member.POST_CODE,
        IFF
        (
            member.DOB IS NULL,
            NULL,
            DATEDIFF(YEAR, member.DOB, CURRENT_DATE())
            - IFF(TO_CHAR(CURRENT_DATE(), 'MMDD') < TO_CHAR(member.DOB, 'MMDD'), 1, 0)
        ) AS AGE,
        IFF
        (
            member.LAST_FLIGHT_DATE IS NULL,
            NULL,
            member.LAST_FLIGHT_DATE < DATEADD(DAY, -90, CURRENT_DATE())
        ) AS STALE_MEMBER,
        member.SOURCE_FILENAME, member.SOURCE_ROW_NUMBER,
        member.SOURCE_FILE_CONTENT_KEY, member.INGESTED_AT, member.SOURCE_RECORD
    FROM SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED AS member
    WHERE member.MEMBER_RECORD_TYPE = 'D'
      AND member.MEMBER_ID IS NOT NULL
      AND NOT EXISTS
      (
          SELECT 1
          FROM SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS failed_rule
          WHERE failed_rule.RUN_ID = :v_run_id
            AND failed_rule.DATASET_NAME = 'MEMBER'
            AND failed_rule.RECORD_KEY = member.RECORD_KEY
            AND failed_rule.STATUS = 'FAILED'
      )
    QUALIFY ROW_NUMBER() OVER
    (
        PARTITION BY member.MEMBER_ID
        ORDER BY member.INGESTED_AT DESC,
                 member.SOURCE_FILENAME DESC,
                 member.SOURCE_ROW_NUMBER DESC,
                 member.SOURCE_FILE_CONTENT_KEY DESC,
                 member.SOURCE_RECORD DESC
    ) = 1;

    SELECT COUNT(*) INTO :v_rows_processed
      FROM SKYPOINTS_DB.CORE.MEMBER_WINNERS;

    BEGIN TRANSACTION;
    v_transaction_started := TRUE;

    UPDATE SKYPOINTS_DB.CORE.MEMBER_HISTORY AS history
       SET EFFECTIVE_TO = :v_processed_at, IS_CURRENT = FALSE
      FROM SKYPOINTS_DB.CORE.MEMBER_WINNERS AS winner
     WHERE history.MEMBER_ID = winner.MEMBER_ID
       AND history.IS_CURRENT
       AND
       (
            history.MEMBER_NAME IS DISTINCT FROM winner.MEMBER_NAME
         OR history.ENROLLMENT_DATE IS DISTINCT FROM winner.ENROLLMENT_DATE
         OR history.LAST_FLIGHT_DATE IS DISTINCT FROM winner.LAST_FLIGHT_DATE
         OR history.TIER_CODE IS DISTINCT FROM winner.TIER_CODE
         OR history.AGENT_NAME IS DISTINCT FROM winner.AGENT_NAME
         OR history.STATE IS DISTINCT FROM winner.STATE
         OR history.COUNTRY IS DISTINCT FROM winner.COUNTRY
         OR history.DOB IS DISTINCT FROM winner.DOB
         OR history.IS_ACTIVE IS DISTINCT FROM winner.IS_ACTIVE
         OR history.POST_CODE IS DISTINCT FROM winner.POST_CODE
       );

    INSERT INTO SKYPOINTS_DB.CORE.MEMBER_HISTORY
    (
        MEMBER_ID, MEMBER_NAME, ENROLLMENT_DATE, LAST_FLIGHT_DATE,
        TIER_CODE, AGENT_NAME, STATE, COUNTRY, DOB, IS_ACTIVE, POST_CODE,
        AGE, STALE_MEMBER, SOURCE_FILENAME, SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY, INGESTED_AT, SOURCE_RECORD,
        EFFECTIVE_FROM, EFFECTIVE_TO, IS_CURRENT
    )
    SELECT
        winner.MEMBER_ID, winner.MEMBER_NAME, winner.ENROLLMENT_DATE,
        winner.LAST_FLIGHT_DATE, winner.TIER_CODE, winner.AGENT_NAME,
        winner.STATE, winner.COUNTRY, winner.DOB, winner.IS_ACTIVE,
        winner.POST_CODE, winner.AGE, winner.STALE_MEMBER,
        winner.SOURCE_FILENAME, winner.SOURCE_ROW_NUMBER,
        winner.SOURCE_FILE_CONTENT_KEY, winner.INGESTED_AT, winner.SOURCE_RECORD,
        :v_processed_at, NULL, TRUE
    FROM SKYPOINTS_DB.CORE.MEMBER_WINNERS AS winner
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM SKYPOINTS_DB.CORE.MEMBER_HISTORY AS current_history
        WHERE current_history.MEMBER_ID = winner.MEMBER_ID
          AND current_history.IS_CURRENT
    );

    MERGE INTO SKYPOINTS_DB.CORE.MEMBER_CURRENT AS target
    USING SKYPOINTS_DB.CORE.MEMBER_WINNERS AS source
       ON target.MEMBER_ID = source.MEMBER_ID
    WHEN MATCHED AND
    (
           target.MEMBER_NAME IS DISTINCT FROM source.MEMBER_NAME
        OR target.ENROLLMENT_DATE IS DISTINCT FROM source.ENROLLMENT_DATE
        OR target.LAST_FLIGHT_DATE IS DISTINCT FROM source.LAST_FLIGHT_DATE
        OR target.TIER_CODE IS DISTINCT FROM source.TIER_CODE
        OR target.AGENT_NAME IS DISTINCT FROM source.AGENT_NAME
        OR target.STATE IS DISTINCT FROM source.STATE
        OR target.COUNTRY IS DISTINCT FROM source.COUNTRY
        OR target.DOB IS DISTINCT FROM source.DOB
        OR target.IS_ACTIVE IS DISTINCT FROM source.IS_ACTIVE
        OR target.POST_CODE IS DISTINCT FROM source.POST_CODE
        OR target.AGE IS DISTINCT FROM source.AGE
        OR target.STALE_MEMBER IS DISTINCT FROM source.STALE_MEMBER
        OR target.SOURCE_FILENAME IS DISTINCT FROM source.SOURCE_FILENAME
        OR target.SOURCE_ROW_NUMBER IS DISTINCT FROM source.SOURCE_ROW_NUMBER
        OR target.SOURCE_FILE_CONTENT_KEY IS DISTINCT FROM source.SOURCE_FILE_CONTENT_KEY
        OR target.INGESTED_AT IS DISTINCT FROM source.INGESTED_AT
        OR target.SOURCE_RECORD IS DISTINCT FROM source.SOURCE_RECORD
    )
    THEN UPDATE SET
        MEMBER_NAME = source.MEMBER_NAME,
        ENROLLMENT_DATE = source.ENROLLMENT_DATE,
        LAST_FLIGHT_DATE = source.LAST_FLIGHT_DATE,
        TIER_CODE = source.TIER_CODE,
        AGENT_NAME = source.AGENT_NAME,
        STATE = source.STATE,
        COUNTRY = source.COUNTRY,
        DOB = source.DOB,
        IS_ACTIVE = source.IS_ACTIVE,
        POST_CODE = source.POST_CODE,
        AGE = source.AGE,
        STALE_MEMBER = source.STALE_MEMBER,
        SOURCE_FILENAME = source.SOURCE_FILENAME,
        SOURCE_ROW_NUMBER = source.SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY = source.SOURCE_FILE_CONTENT_KEY,
        INGESTED_AT = source.INGESTED_AT,
        SOURCE_RECORD = source.SOURCE_RECORD,
        LAST_PROCESSED_RUN_ID = :v_run_id,
        UPDATED_AT = :v_processed_at
    WHEN NOT MATCHED THEN INSERT
    (
        MEMBER_ID, MEMBER_NAME, ENROLLMENT_DATE, LAST_FLIGHT_DATE,
        TIER_CODE, AGENT_NAME, STATE, COUNTRY, DOB, IS_ACTIVE, POST_CODE,
        AGE, STALE_MEMBER, SOURCE_FILENAME, SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY, INGESTED_AT, SOURCE_RECORD,
        LAST_PROCESSED_RUN_ID, UPDATED_AT
    )
    VALUES
    (
        source.MEMBER_ID, source.MEMBER_NAME, source.ENROLLMENT_DATE,
        source.LAST_FLIGHT_DATE, source.TIER_CODE, source.AGENT_NAME,
        source.STATE, source.COUNTRY, source.DOB, source.IS_ACTIVE,
        source.POST_CODE, source.AGE, source.STALE_MEMBER,
        source.SOURCE_FILENAME, source.SOURCE_ROW_NUMBER,
        source.SOURCE_FILE_CONTENT_KEY, source.INGESTED_AT, source.SOURCE_RECORD,
        :v_run_id, :v_processed_at
    );

    COMMIT;
    v_transaction_started := FALSE;

    UPDATE SKYPOINTS_DB.AUDIT.PHASE45_AUDIT
       SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'SUCCEEDED',
           ROWS_PROCESSED = :v_rows_processed
     WHERE RUN_ID = :v_run_id AND TASK_NAME = 'TASK_MEMBER_PROCESSING';

    RETURN OBJECT_CONSTRUCT('run_id', v_run_id, 'members_processed', v_rows_processed);
EXCEPTION
    WHEN OTHER THEN
        IF (v_transaction_started) THEN
            ROLLBACK;
        END IF;
        UPDATE SKYPOINTS_DB.AUDIT.PHASE45_AUDIT
           SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'FAILED',
               ERROR_DETAILS = :SQLERRM
         WHERE RUN_ID = :v_run_id AND TASK_NAME = 'TASK_MEMBER_PROCESSING';
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.CORE.SP_PROCESS_REDEMPTIONS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id VARCHAR;
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_processed_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_rows_processed NUMBER(38, 0) DEFAULT 0;
BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')
      INTO :v_run_id;

    MERGE INTO SKYPOINTS_DB.AUDIT.PHASE45_AUDIT AS target
    USING (SELECT :v_run_id AS RUN_ID, 'TASK_REDEMPTION_PROCESSING' AS TASK_NAME) AS source
       ON target.RUN_ID = source.RUN_ID AND target.TASK_NAME = source.TASK_NAME
    WHEN MATCHED THEN UPDATE SET
        STARTED_AT = :v_started_at, ENDED_AT = NULL, STATUS = 'STARTED',
        ROWS_PROCESSED = 0, ERROR_DETAILS = NULL
    WHEN NOT MATCHED THEN INSERT
        (RUN_ID, TASK_NAME, STARTED_AT, STATUS, ROWS_PROCESSED)
    VALUES
        (source.RUN_ID, source.TASK_NAME, :v_started_at, 'STARTED', 0);

    -- Enforce referential integrity again against the committed current member
    -- table so no transaction can be filtered out without a quarantine reason.
    MERGE INTO SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS target
    USING
    (
        SELECT
            :v_run_id AS RUN_ID,
            'REDEMPTION' AS DATASET_NAME,
            redemption.RECORD_KEY,
            'MEMBER_EXISTS' AS RULE_ID,
            'Member exists after member processing' AS RULE_NAME,
            'FAILED' AS STATUS,
            redemption.SOURCE_FILENAME,
            redemption.SOURCE_ROW_NUMBER,
            redemption.SOURCE_FILE_CONTENT_KEY
        FROM SKYPOINTS_DB.STAGING.REDEMPTION_PARSED AS redemption
        WHERE redemption.MEMBER_ID IS NOT NULL
          AND NOT EXISTS
          (
              SELECT 1
              FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT AS current_member
              WHERE current_member.MEMBER_ID = redemption.MEMBER_ID
          )
    ) AS source
       ON target.RUN_ID = source.RUN_ID
      AND target.DATASET_NAME = source.DATASET_NAME
      AND target.RECORD_KEY = source.RECORD_KEY
      AND target.RULE_ID = source.RULE_ID
    WHEN MATCHED THEN UPDATE SET
        RULE_NAME = source.RULE_NAME,
        STATUS = source.STATUS,
        EVALUATED_COUNT = 1,
        FAILURE_COUNT = 1,
        FAILURE_REASON = 'MEMBER_ID does not identify a valid current member',
        SOURCE_FILENAME = source.SOURCE_FILENAME,
        SOURCE_ROW_NUMBER = source.SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY = source.SOURCE_FILE_CONTENT_KEY,
        EXECUTED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
    (
        RUN_ID, DATASET_NAME, RECORD_KEY, RULE_ID, RULE_NAME, STATUS,
        EVALUATED_COUNT, FAILURE_COUNT, FAILURE_REASON, SOURCE_FILENAME,
        SOURCE_ROW_NUMBER, SOURCE_FILE_CONTENT_KEY, EXECUTED_AT
    )
    VALUES
    (
        source.RUN_ID, source.DATASET_NAME, source.RECORD_KEY,
        source.RULE_ID, source.RULE_NAME, source.STATUS, 1, 1,
        'MEMBER_ID does not identify a valid current member',
        source.SOURCE_FILENAME, source.SOURCE_ROW_NUMBER,
        source.SOURCE_FILE_CONTENT_KEY, CURRENT_TIMESTAMP()
    );

    MERGE INTO SKYPOINTS_DB.STAGING.DQ_QUARANTINE AS target
    USING
    (
        SELECT
            :v_run_id AS RUN_ID, 'REDEMPTION' AS DATASET_NAME,
            redemption.RECORD_KEY, redemption.SOURCE_FILENAME,
            redemption.SOURCE_ROW_NUMBER, redemption.SOURCE_FILE_CONTENT_KEY,
            NULL::VARCHAR AS ORIGINAL_RECORD,
            redemption.ORIGINAL_PAYLOAD,
            redemption.TRANSACTION_INDEX,
            ARRAY_AGG(OBJECT_CONSTRUCT(
                'rule_id', result.RULE_ID,
                'rule_name', result.RULE_NAME,
                'message', result.FAILURE_REASON
            )) WITHIN GROUP (ORDER BY result.RULE_ID) AS FAILURE_REASONS
        FROM SKYPOINTS_DB.STAGING.REDEMPTION_PARSED AS redemption
        JOIN SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS result
          ON result.RECORD_KEY = redemption.RECORD_KEY
         AND result.RUN_ID = :v_run_id
         AND result.DATASET_NAME = 'REDEMPTION'
         AND result.STATUS = 'FAILED'
        GROUP BY redemption.RECORD_KEY, redemption.SOURCE_FILENAME,
                 redemption.SOURCE_ROW_NUMBER, redemption.SOURCE_FILE_CONTENT_KEY,
                 redemption.ORIGINAL_PAYLOAD, redemption.TRANSACTION_INDEX
    ) AS source
       ON target.DATASET_NAME = source.DATASET_NAME
      AND target.RECORD_KEY = source.RECORD_KEY
    WHEN MATCHED THEN UPDATE SET
        FAILURE_REASONS = source.FAILURE_REASONS
    WHEN NOT MATCHED THEN INSERT
    (
        RUN_ID, DATASET_NAME, RECORD_KEY, SOURCE_FILENAME, SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY, ORIGINAL_RECORD, ORIGINAL_PAYLOAD,
        TRANSACTION_INDEX, FAILURE_REASONS, QUARANTINED_AT
    )
    VALUES
    (
        source.RUN_ID, source.DATASET_NAME, source.RECORD_KEY,
        source.SOURCE_FILENAME, source.SOURCE_ROW_NUMBER,
        source.SOURCE_FILE_CONTENT_KEY, source.ORIGINAL_RECORD,
        source.ORIGINAL_PAYLOAD, source.TRANSACTION_INDEX,
        source.FAILURE_REASONS, CURRENT_TIMESTAMP()
    );

    MERGE INTO SKYPOINTS_DB.AUDIT.DQ_EXECUTION AS target
    USING
    (
        SELECT
            :v_run_id AS RUN_ID,
            'REDEMPTION' AS DATASET_NAME,
            COUNT(*) AS INVALID_RECORDS
        FROM
        (
            SELECT RECORD_KEY
            FROM SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT
            WHERE RUN_ID = :v_run_id
              AND DATASET_NAME = 'REDEMPTION'
              AND STATUS = 'FAILED'
            GROUP BY RECORD_KEY
        ) AS failed_redemptions
    ) AS source
       ON target.RUN_ID = source.RUN_ID
      AND target.DATASET_NAME = source.DATASET_NAME
    WHEN MATCHED THEN UPDATE SET
        INVALID_RECORDS = source.INVALID_RECORDS,
        VALID_RECORDS = GREATEST(target.TOTAL_RECORDS - source.INVALID_RECORDS, 0),
        ENDED_AT = CURRENT_TIMESTAMP();

    CREATE OR REPLACE TEMPORARY TABLE SKYPOINTS_DB.CORE.REDEMPTION_WINNERS AS
    SELECT
        redemption.REDEMPTION_ID, redemption.MEMBER_ID, redemption.FEED_DATE,
        UPPER(redemption.STATUS) AS STATUS, redemption.POINTS,
        redemption.SOURCE_FILENAME, redemption.SOURCE_ROW_NUMBER,
        redemption.SOURCE_FILE_CONTENT_KEY, redemption.TRANSACTION_INDEX,
        redemption.INGESTED_AT, redemption.ORIGINAL_PAYLOAD
    FROM SKYPOINTS_DB.STAGING.REDEMPTION_PARSED AS redemption
    WHERE redemption.REDEMPTION_ID IS NOT NULL
      AND redemption.MEMBER_ID IS NOT NULL
      AND EXISTS
      (
          SELECT 1
          FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT AS current_member
          WHERE current_member.MEMBER_ID = redemption.MEMBER_ID
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT AS failed_rule
          WHERE failed_rule.RUN_ID = :v_run_id
            AND failed_rule.DATASET_NAME = 'REDEMPTION'
            AND failed_rule.RECORD_KEY = redemption.RECORD_KEY
            AND failed_rule.STATUS = 'FAILED'
      )
    QUALIFY ROW_NUMBER() OVER
    (
        PARTITION BY redemption.REDEMPTION_ID
        ORDER BY redemption.INGESTED_AT DESC,
                 redemption.SOURCE_FILENAME DESC,
                 redemption.SOURCE_ROW_NUMBER DESC,
                 redemption.TRANSACTION_INDEX DESC,
                 redemption.SOURCE_FILE_CONTENT_KEY DESC,
                 TO_JSON(redemption.ORIGINAL_PAYLOAD) DESC
    ) = 1;

    SELECT COUNT(*) INTO :v_rows_processed
      FROM SKYPOINTS_DB.CORE.REDEMPTION_WINNERS;

    MERGE INTO SKYPOINTS_DB.CORE.REDEMPTION_FACT AS target
    USING SKYPOINTS_DB.CORE.REDEMPTION_WINNERS AS source
       ON target.REDEMPTION_ID = source.REDEMPTION_ID
    WHEN MATCHED AND
    (
           target.MEMBER_ID IS DISTINCT FROM source.MEMBER_ID
        OR target.FEED_DATE IS DISTINCT FROM source.FEED_DATE
        OR target.STATUS IS DISTINCT FROM source.STATUS
        OR target.POINTS IS DISTINCT FROM source.POINTS
        OR target.SOURCE_FILENAME IS DISTINCT FROM source.SOURCE_FILENAME
        OR target.SOURCE_ROW_NUMBER IS DISTINCT FROM source.SOURCE_ROW_NUMBER
        OR target.SOURCE_FILE_CONTENT_KEY IS DISTINCT FROM source.SOURCE_FILE_CONTENT_KEY
        OR target.TRANSACTION_INDEX IS DISTINCT FROM source.TRANSACTION_INDEX
        OR target.INGESTED_AT IS DISTINCT FROM source.INGESTED_AT
        OR target.ORIGINAL_PAYLOAD IS DISTINCT FROM source.ORIGINAL_PAYLOAD
    )
    THEN UPDATE SET
        MEMBER_ID = source.MEMBER_ID,
        FEED_DATE = source.FEED_DATE,
        STATUS = source.STATUS,
        POINTS = source.POINTS,
        SOURCE_FILENAME = source.SOURCE_FILENAME,
        SOURCE_ROW_NUMBER = source.SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY = source.SOURCE_FILE_CONTENT_KEY,
        TRANSACTION_INDEX = source.TRANSACTION_INDEX,
        INGESTED_AT = source.INGESTED_AT,
        ORIGINAL_PAYLOAD = source.ORIGINAL_PAYLOAD,
        LAST_PROCESSED_RUN_ID = :v_run_id,
        UPDATED_AT = :v_processed_at
    WHEN NOT MATCHED THEN INSERT
    (
        REDEMPTION_ID, MEMBER_ID, FEED_DATE, STATUS, POINTS,
        SOURCE_FILENAME, SOURCE_ROW_NUMBER, SOURCE_FILE_CONTENT_KEY,
        TRANSACTION_INDEX, INGESTED_AT, ORIGINAL_PAYLOAD,
        LAST_PROCESSED_RUN_ID, UPDATED_AT
    )
    VALUES
    (
        source.REDEMPTION_ID, source.MEMBER_ID, source.FEED_DATE,
        source.STATUS, source.POINTS, source.SOURCE_FILENAME,
        source.SOURCE_ROW_NUMBER, source.SOURCE_FILE_CONTENT_KEY,
        source.TRANSACTION_INDEX, source.INGESTED_AT, source.ORIGINAL_PAYLOAD,
        :v_run_id, :v_processed_at
    );

    UPDATE SKYPOINTS_DB.AUDIT.PHASE45_AUDIT
       SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'SUCCEEDED',
           ROWS_PROCESSED = :v_rows_processed
     WHERE RUN_ID = :v_run_id AND TASK_NAME = 'TASK_REDEMPTION_PROCESSING';

    RETURN OBJECT_CONSTRUCT('run_id', v_run_id, 'redemptions_processed', v_rows_processed);
EXCEPTION
    WHEN OTHER THEN
        UPDATE SKYPOINTS_DB.AUDIT.PHASE45_AUDIT
           SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'FAILED',
               ERROR_DETAILS = :SQLERRM
         WHERE RUN_ID = :v_run_id AND TASK_NAME = 'TASK_REDEMPTION_PROCESSING';
        RAISE;
END;
$$;

-- New tasks are suspended by default. Also suspend the two existing Phase 3
-- descendants so the complete graph remains dormant until manual execution.
CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_PARSE_AND_NORMALIZE
    WAREHOUSE = 'SKYPOINTS_ETL_WH'
    COMMENT = 'Parse immutable raw records into typed staging rows'
    AFTER SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION
AS
    CALL SKYPOINTS_DB.STAGING.SP_PARSE_AND_NORMALIZE();

CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_DQ_VALIDATION
    WAREHOUSE = 'SKYPOINTS_ETL_WH'
    COMMENT = 'Evaluate allowlisted metadata-driven DQ rules and quarantine failures'
    AFTER SKYPOINTS_DB.RAW.TASK_PARSE_AND_NORMALIZE
AS
    CALL SKYPOINTS_DB.STAGING.SP_RUN_DQ_VALIDATION();

CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_PROCESSING
    WAREHOUSE = 'SKYPOINTS_ETL_WH'
    COMMENT = 'Deduplicate valid members and maintain current and history tables'
    AFTER SKYPOINTS_DB.RAW.TASK_DQ_VALIDATION
AS
    CALL SKYPOINTS_DB.CORE.SP_PROCESS_MEMBERS();

CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_PROCESSING
    WAREHOUSE = 'SKYPOINTS_ETL_WH'
    COMMENT = 'Validate, deduplicate, and merge member-linked redemption facts'
    AFTER SKYPOINTS_DB.RAW.TASK_MEMBER_PROCESSING
AS
    CALL SKYPOINTS_DB.CORE.SP_PROCESS_REDEMPTIONS();

ALTER TASK SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION SUSPEND;
