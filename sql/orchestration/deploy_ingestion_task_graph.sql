CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
(
    RUN_ID VARCHAR NOT NULL,
    TASK_NAME VARCHAR NOT NULL,
    STARTED_AT TIMESTAMP_LTZ NOT NULL,
    ENDED_AT TIMESTAMP_LTZ,
    STATUS VARCHAR NOT NULL,
    ROWS_LOADED NUMBER(38, 0) NOT NULL DEFAULT 0,
    MEMBER_ROW_COUNT NUMBER(38, 0),
    REDEMPTION_ROW_COUNT NUMBER(38, 0),
    SOURCE_FILES VARIANT,
    ERROR_DETAILS VARCHAR
)
COMMENT = 'Per-task audit records for the SkyPoints raw ingestion task graph';

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.RAW.SP_RUN_MEMBER_INGESTION()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id VARCHAR;
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_copy_query_id VARCHAR;
    v_rows_loaded NUMBER(38, 0) DEFAULT 0;
    v_source_files VARIANT DEFAULT ARRAY_CONSTRUCT();
BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')
      INTO :v_run_id;

    INSERT INTO SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
    (
        RUN_ID,
        TASK_NAME,
        STARTED_AT,
        STATUS,
        ROWS_LOADED,
        SOURCE_FILES
    )
    SELECT
        :v_run_id,
        'TASK_MEMBER_INGESTION',
        :v_started_at,
        'RUNNING',
        0,
        :v_source_files;

    COPY INTO SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW
    (
        SOURCE_RECORD,
        SOURCE_FILENAME,
        SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY,
        INGESTED_AT
    )
    FROM
    (
        SELECT
            $1::VARCHAR,
            METADATA$FILENAME::VARCHAR,
            METADATA$FILE_ROW_NUMBER::NUMBER(38, 0),
            METADATA$FILE_CONTENT_KEY::VARCHAR,
            METADATA$START_SCAN_TIME::TIMESTAMP_LTZ
        FROM @SKYPOINTS_DB.RAW.MEMBER_S3_STAGE
    )
    FILE_FORMAT = (FORMAT_NAME = SKYPOINTS_DB.RAW.MEMBER_PROFILE_CSV)
    ON_ERROR = 'ABORT_STATEMENT';

    v_copy_query_id := LAST_QUERY_ID();

    SELECT
        COALESCE(SUM(ROWS_LOADED), 0),
        COALESCE(ARRAY_AGG(DISTINCT FILE), ARRAY_CONSTRUCT())
      INTO :v_rows_loaded, :v_source_files
      FROM TABLE(RESULT_SCAN(:v_copy_query_id));

    UPDATE SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
       SET ENDED_AT = CURRENT_TIMESTAMP(),
           STATUS = 'SUCCEEDED',
           ROWS_LOADED = :v_rows_loaded,
           SOURCE_FILES = :v_source_files
     WHERE RUN_ID = :v_run_id
       AND TASK_NAME = 'TASK_MEMBER_INGESTION'
       AND STATUS = 'RUNNING';

    RETURN OBJECT_CONSTRUCT(
        'run_id', v_run_id,
        'rows_loaded', v_rows_loaded,
        'source_files', v_source_files
    );
EXCEPTION
    WHEN OTHER THEN
        UPDATE SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
           SET ENDED_AT = CURRENT_TIMESTAMP(),
               STATUS = 'FAILED',
               ERROR_DETAILS = :SQLERRM
         WHERE RUN_ID = :v_run_id
           AND TASK_NAME = 'TASK_MEMBER_INGESTION'
           AND STATUS = 'RUNNING';
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.RAW.SP_RUN_REDEMPTION_INGESTION()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id VARCHAR;
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_copy_query_id VARCHAR;
    v_rows_loaded NUMBER(38, 0) DEFAULT 0;
    v_source_files VARIANT DEFAULT ARRAY_CONSTRUCT();
BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')
      INTO :v_run_id;

    INSERT INTO SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
    (
        RUN_ID,
        TASK_NAME,
        STARTED_AT,
        STATUS,
        ROWS_LOADED,
        SOURCE_FILES
    )
    SELECT
        :v_run_id,
        'TASK_REDEMPTION_INGESTION',
        :v_started_at,
        'RUNNING',
        0,
        :v_source_files;

    COPY INTO SKYPOINTS_DB.RAW.REDEMPTION_RAW
    (
        PAYLOAD,
        SOURCE_FILENAME,
        SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY,
        INGESTED_AT
    )
    FROM
    (
        SELECT
            $1::VARIANT,
            METADATA$FILENAME::VARCHAR,
            METADATA$FILE_ROW_NUMBER::NUMBER(38, 0),
            METADATA$FILE_CONTENT_KEY::VARCHAR,
            METADATA$START_SCAN_TIME::TIMESTAMP_LTZ
        FROM @SKYPOINTS_DB.RAW.REDEMPTION_S3_STAGE
    )
    FILE_FORMAT = (FORMAT_NAME = SKYPOINTS_DB.RAW.REDEMPTION_JSON)
    ON_ERROR = 'ABORT_STATEMENT';

    v_copy_query_id := LAST_QUERY_ID();

    SELECT
        COALESCE(SUM(ROWS_LOADED), 0),
        COALESCE(ARRAY_AGG(DISTINCT FILE), ARRAY_CONSTRUCT())
      INTO :v_rows_loaded, :v_source_files
      FROM TABLE(RESULT_SCAN(:v_copy_query_id));

    UPDATE SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
       SET ENDED_AT = CURRENT_TIMESTAMP(),
           STATUS = 'SUCCEEDED',
           ROWS_LOADED = :v_rows_loaded,
           SOURCE_FILES = :v_source_files
     WHERE RUN_ID = :v_run_id
       AND TASK_NAME = 'TASK_REDEMPTION_INGESTION'
       AND STATUS = 'RUNNING';

    RETURN OBJECT_CONSTRUCT(
        'run_id', v_run_id,
        'rows_loaded', v_rows_loaded,
        'source_files', v_source_files
    );
EXCEPTION
    WHEN OTHER THEN
        UPDATE SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
           SET ENDED_AT = CURRENT_TIMESTAMP(),
               STATUS = 'FAILED',
               ERROR_DETAILS = :SQLERRM
         WHERE RUN_ID = :v_run_id
           AND TASK_NAME = 'TASK_REDEMPTION_INGESTION'
           AND STATUS = 'RUNNING';
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.RAW.SP_RUN_INGESTION_VALIDATION()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    e_validation_failed EXCEPTION (-20001, 'Critical raw-table validation failed');
    v_run_id VARCHAR;
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_member_row_count NUMBER(38, 0) DEFAULT 0;
    v_redemption_row_count NUMBER(38, 0) DEFAULT 0;
    v_member_invalid_count NUMBER(38, 0) DEFAULT 0;
    v_redemption_invalid_count NUMBER(38, 0) DEFAULT 0;
    v_member_files VARIANT DEFAULT ARRAY_CONSTRUCT();
    v_redemption_files VARIANT DEFAULT ARRAY_CONSTRUCT();
    v_source_files VARIANT DEFAULT OBJECT_CONSTRUCT();
    v_error_details VARCHAR;
BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')
      INTO :v_run_id;

    INSERT INTO SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
    (
        RUN_ID,
        TASK_NAME,
        STARTED_AT,
        STATUS,
        ROWS_LOADED
    )
    SELECT
        :v_run_id,
        'TASK_INGESTION_VALIDATION',
        :v_started_at,
        'RUNNING',
        0;

    SELECT
        COUNT(*),
        COALESCE(
            COUNT_IF(
                SOURCE_RECORD IS NULL
                OR SOURCE_FILENAME IS NULL
                OR SOURCE_ROW_NUMBER IS NULL
                OR SOURCE_FILE_CONTENT_KEY IS NULL
                OR INGESTED_AT IS NULL
            ),
            0
        )
      INTO :v_member_row_count, :v_member_invalid_count
      FROM SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW;

    SELECT
        COUNT(*),
        COALESCE(
            COUNT_IF(
                PAYLOAD IS NULL
                OR SOURCE_FILENAME IS NULL
                OR SOURCE_ROW_NUMBER IS NULL
                OR SOURCE_FILE_CONTENT_KEY IS NULL
                OR INGESTED_AT IS NULL
            ),
            0
        )
      INTO :v_redemption_row_count, :v_redemption_invalid_count
      FROM SKYPOINTS_DB.RAW.REDEMPTION_RAW;

    SELECT COALESCE(SOURCE_FILES, ARRAY_CONSTRUCT())
      INTO :v_member_files
      FROM SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
     WHERE RUN_ID = :v_run_id
       AND TASK_NAME = 'TASK_MEMBER_INGESTION'
     ORDER BY STARTED_AT DESC
     LIMIT 1;

    SELECT COALESCE(SOURCE_FILES, ARRAY_CONSTRUCT())
      INTO :v_redemption_files
      FROM SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
     WHERE RUN_ID = :v_run_id
       AND TASK_NAME = 'TASK_REDEMPTION_INGESTION'
     ORDER BY STARTED_AT DESC
     LIMIT 1;

    v_source_files := OBJECT_CONSTRUCT(
        'members', v_member_files,
        'redemptions', v_redemption_files
    );

    IF (
        v_member_row_count = 0
        OR v_redemption_row_count = 0
        OR v_member_invalid_count > 0
        OR v_redemption_invalid_count > 0
    ) THEN
        v_error_details :=
            'Raw table validation failed: member_row_count='
            || v_member_row_count
            || ', redemption_row_count='
            || v_redemption_row_count
            || ', member_invalid_count='
            || v_member_invalid_count
            || ', redemption_invalid_count='
            || v_redemption_invalid_count;
        RAISE e_validation_failed;
    END IF;

    UPDATE SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
       SET ENDED_AT = CURRENT_TIMESTAMP(),
           STATUS = 'SUCCEEDED',
           MEMBER_ROW_COUNT = :v_member_row_count,
           REDEMPTION_ROW_COUNT = :v_redemption_row_count,
           SOURCE_FILES = :v_source_files
     WHERE RUN_ID = :v_run_id
       AND TASK_NAME = 'TASK_INGESTION_VALIDATION'
       AND STATUS = 'RUNNING';

    RETURN OBJECT_CONSTRUCT(
        'run_id', v_run_id,
        'member_row_count', v_member_row_count,
        'redemption_row_count', v_redemption_row_count,
        'source_files', v_source_files
    );
EXCEPTION
    WHEN OTHER THEN
        UPDATE SKYPOINTS_DB.AUDIT.INGESTION_AUDIT
           SET ENDED_AT = CURRENT_TIMESTAMP(),
               STATUS = 'FAILED',
               MEMBER_ROW_COUNT = :v_member_row_count,
               REDEMPTION_ROW_COUNT = :v_redemption_row_count,
               SOURCE_FILES = :v_source_files,
               ERROR_DETAILS = COALESCE(:v_error_details, :SQLERRM)
         WHERE RUN_ID = :v_run_id
           AND TASK_NAME = 'TASK_INGESTION_VALIDATION'
           AND STATUS = 'RUNNING';
        RAISE;
END;
$$;

CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION
    WAREHOUSE = 'SKYPOINTS_ETL_WH'
    COMMENT = 'Root task: copy staged member records into the raw table'
AS
    CALL SKYPOINTS_DB.RAW.SP_RUN_MEMBER_INGESTION();

CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION
    WAREHOUSE = 'SKYPOINTS_ETL_WH'
    COMMENT = 'Copy staged redemption documents after member ingestion succeeds'
    AFTER SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION
AS
    CALL SKYPOINTS_DB.RAW.SP_RUN_REDEMPTION_INGESTION();

CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION
    WAREHOUSE = 'SKYPOINTS_ETL_WH'
    COMMENT = 'Validate both raw tables after both ingestion tasks succeed'
    AFTER SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION
AS
    CALL SKYPOINTS_DB.RAW.SP_RUN_INGESTION_VALIDATION();
