-- Phase 7B/7D: controlled manual orchestration and run-level audit.
-- Deploy after the Phase 3-6C task graph and processing objects.

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.PIPELINE_RUN_AUDIT
(
    RUN_ID VARCHAR NOT NULL,
    GRAPH_RUN_ID VARCHAR,
    STATUS VARCHAR NOT NULL,
    STARTED_AT TIMESTAMP_LTZ NOT NULL,
    ENDED_AT TIMESTAMP_LTZ,
    TASK_COUNT NUMBER(38, 0) NOT NULL DEFAULT 0,
    FAILED_TASKS VARCHAR,
    ERROR_DETAILS VARCHAR,
    CLEANUP_ERRORS VARCHAR,
    PRIMARY KEY (RUN_ID)
)
COMMENT = 'Controlled manual Phase 3-6C graph execution outcomes';

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.PIPELINE_RUN_CONTROL
(
    CONTROL_NAME VARCHAR NOT NULL,
    STATUS VARCHAR NOT NULL,
    ACTIVE_RUN_ID VARCHAR,
    UPDATED_AT TIMESTAMP_LTZ NOT NULL,
    PRIMARY KEY (CONTROL_NAME)
)
COMMENT = 'Single-run guard for the unified manual pipeline entry point';

MERGE INTO SKYPOINTS_DB.AUDIT.PIPELINE_RUN_CONTROL AS target
USING (SELECT 'PHASE3_6C' AS CONTROL_NAME) AS source
   ON target.CONTROL_NAME = source.CONTROL_NAME
WHEN NOT MATCHED THEN INSERT
    (CONTROL_NAME, STATUS, ACTIVE_RUN_ID, UPDATED_AT)
VALUES
    (source.CONTROL_NAME, 'IDLE', NULL, CURRENT_TIMESTAMP());

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.AUDIT.SP_SUSPEND_PIPELINE_DESCENDANTS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_errors VARCHAR DEFAULT '';
BEGIN
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_RECONCILIATION SUSPEND';
    EXCEPTION
        WHEN OTHER THEN
            v_errors := v_errors || 'TASK_COUNTRY_RECONCILIATION: ' || SQLERRM || '; ';
    END;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING SUSPEND';
    EXCEPTION
        WHEN OTHER THEN
            v_errors := v_errors || 'TASK_COUNTRY_ROUTING: ' || SQLERRM || '; ';
    END;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_PROCESSING SUSPEND';
    EXCEPTION
        WHEN OTHER THEN
            v_errors := v_errors || 'TASK_REDEMPTION_PROCESSING: ' || SQLERRM || '; ';
    END;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_PROCESSING SUSPEND';
    EXCEPTION
        WHEN OTHER THEN
            v_errors := v_errors || 'TASK_MEMBER_PROCESSING: ' || SQLERRM || '; ';
    END;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_DQ_VALIDATION SUSPEND';
    EXCEPTION
        WHEN OTHER THEN
            v_errors := v_errors || 'TASK_DQ_VALIDATION: ' || SQLERRM || '; ';
    END;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_PARSE_AND_NORMALIZE SUSPEND';
    EXCEPTION
        WHEN OTHER THEN
            v_errors := v_errors || 'TASK_PARSE_AND_NORMALIZE: ' || SQLERRM || '; ';
    END;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION SUSPEND';
    EXCEPTION
        WHEN OTHER THEN
            v_errors := v_errors || 'TASK_INGESTION_VALIDATION: ' || SQLERRM || '; ';
    END;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION SUSPEND';
    EXCEPTION
        WHEN OTHER THEN
            v_errors := v_errors || 'TASK_REDEMPTION_INGESTION: ' || SQLERRM || '; ';
    END;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION SUSPEND';
    EXCEPTION
        WHEN OTHER THEN
            v_errors := v_errors || 'TASK_MEMBER_INGESTION: ' || SQLERRM || '; ';
    END;
    RETURN NULLIF(v_errors, '');
END;
$$;

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.AUDIT.SP_RUN_COMPLETE_PIPELINE()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    e_cleanup_failed EXCEPTION
        (-20071, 'Pipeline completed but one or more task descendants could not be suspended');
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_graph_run_id VARCHAR;
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_lock_acquired BOOLEAN DEFAULT FALSE;
    v_lock_rows NUMBER(38, 0) DEFAULT 0;
    v_task_count NUMBER(38, 0) DEFAULT 0;
    v_success_count NUMBER(38, 0) DEFAULT 0;
    v_failed_task_count NUMBER(38, 0) DEFAULT 0;
    v_failed_tasks VARCHAR;
    v_task_errors VARCHAR;
    v_reconciliation_error VARCHAR;
    v_cleanup_errors VARCHAR;
    v_error_details VARCHAR;
BEGIN
    INSERT INTO SKYPOINTS_DB.AUDIT.PIPELINE_RUN_AUDIT
    (
        RUN_ID, STATUS, STARTED_AT, TASK_COUNT
    )
    SELECT :v_run_id, 'STARTED', :v_started_at, 0;

    BEGIN TRANSACTION;
    UPDATE SKYPOINTS_DB.AUDIT.PIPELINE_RUN_CONTROL
       SET STATUS = 'RUNNING',
           ACTIVE_RUN_ID = :v_run_id,
           UPDATED_AT = CURRENT_TIMESTAMP()
     WHERE CONTROL_NAME = 'PHASE3_6C'
       AND STATUS = 'IDLE';
    v_lock_rows := SQLROWCOUNT;
    COMMIT;

    IF (v_lock_rows = 0) THEN
        UPDATE SKYPOINTS_DB.AUDIT.PIPELINE_RUN_AUDIT
           SET STATUS = 'BLOCKED',
               ENDED_AT = CURRENT_TIMESTAMP(),
               ERROR_DETAILS = 'Another unified pipeline execution holds the run lock'
         WHERE RUN_ID = :v_run_id;
        RETURN OBJECT_CONSTRUCT(
            'run_id', v_run_id,
            'status', 'BLOCKED',
            'message', 'Another unified pipeline execution is active'
        );
    END IF;
    v_lock_acquired := TRUE;

    EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_RECONCILIATION RESUME';
    EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING RESUME';
    EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_PROCESSING RESUME';
    EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_PROCESSING RESUME';
    EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_DQ_VALIDATION RESUME';
    EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_PARSE_AND_NORMALIZE RESUME';
    EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION RESUME';
    EXECUTE IMMEDIATE 'ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION RESUME';

    EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT;

    SELECT COALESCE(MAX(GRAPH_RUN_GROUP_ID), :v_run_id)
      INTO :v_graph_run_id
      FROM
      (
          SELECT GRAPH_RUN_GROUP_ID
          FROM TABLE(SKYPOINTS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
              SCHEDULED_TIME_RANGE_START => :v_started_at,
              SCHEDULED_TIME_RANGE_END => CURRENT_TIMESTAMP(),
              TASK_NAME => 'TASK_MEMBER_INGESTION',
              DATABASE_NAME => 'SKYPOINTS_DB',
              SCHEMA_NAME => 'RAW',
              RESULT_LIMIT => 1000
          ))
          WHERE GRAPH_RUN_GROUP_ID IS NOT NULL
          QUALIFY ROW_NUMBER() OVER (ORDER BY SCHEDULED_TIME DESC) = 1
      ) AS root_run;

    SELECT COUNT(*),
           COALESCE(COUNT_IF(STATE = 'SUCCEEDED'), 0),
           COALESCE(COUNT_IF(STATE IN ('FAILED', 'CANCELLED')), 0),
           LISTAGG(IFF(STATE <> 'SUCCEEDED', NAME, NULL), ', ')
               WITHIN GROUP (ORDER BY SCHEDULED_TIME),
           LISTAGG(
               IFF(STATE <> 'SUCCEEDED',
                   NAME || '=' || STATE || COALESCE(': ' || ERROR_MESSAGE, ''),
                   NULL),
               '; '
           ) WITHIN GROUP (ORDER BY SCHEDULED_TIME)
      INTO :v_task_count, :v_success_count, :v_failed_task_count,
           :v_failed_tasks, :v_task_errors
      FROM TABLE(SKYPOINTS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
          SCHEDULED_TIME_RANGE_START => :v_started_at,
          SCHEDULED_TIME_RANGE_END => CURRENT_TIMESTAMP(),
          DATABASE_NAME => 'SKYPOINTS_DB',
          SCHEMA_NAME => 'RAW',
          RESULT_LIMIT => 1000
      ))
     WHERE GRAPH_RUN_GROUP_ID = :v_graph_run_id
       AND NAME IN
       (
           'TASK_MEMBER_INGESTION',
           'TASK_REDEMPTION_INGESTION',
           'TASK_INGESTION_VALIDATION',
           'TASK_PARSE_AND_NORMALIZE',
           'TASK_DQ_VALIDATION',
           'TASK_MEMBER_PROCESSING',
           'TASK_REDEMPTION_PROCESSING',
           'TASK_COUNTRY_ROUTING',
           'TASK_COUNTRY_RECONCILIATION'
       );

    CALL SKYPOINTS_DB.AUDIT.SP_SUSPEND_PIPELINE_DESCENDANTS()
      INTO :v_cleanup_errors;

    IF (v_task_count <> 9 OR v_success_count <> 9 OR v_failed_task_count > 0) THEN
        v_error_details := COALESCE(
            v_task_errors,
            'Task history did not contain nine successful task executions'
        );
        RAISE e_cleanup_failed;
    END IF;

    IF (v_cleanup_errors IS NOT NULL) THEN
        v_error_details := 'Task graph succeeded, but cleanup failed: '
            || v_cleanup_errors;
        RAISE e_cleanup_failed;
    END IF;

    UPDATE SKYPOINTS_DB.AUDIT.PIPELINE_RUN_AUDIT
       SET GRAPH_RUN_ID = :v_graph_run_id,
           STATUS = 'SUCCEEDED',
           ENDED_AT = CURRENT_TIMESTAMP(),
           TASK_COUNT = :v_task_count,
           FAILED_TASKS = NULL,
           ERROR_DETAILS = NULL,
           CLEANUP_ERRORS = NULL
     WHERE RUN_ID = :v_run_id;

    UPDATE SKYPOINTS_DB.AUDIT.PIPELINE_RUN_CONTROL
       SET STATUS = 'IDLE', ACTIVE_RUN_ID = NULL, UPDATED_AT = CURRENT_TIMESTAMP()
     WHERE CONTROL_NAME = 'PHASE3_6C'
       AND ACTIVE_RUN_ID = :v_run_id;
    v_lock_acquired := FALSE;

    RETURN OBJECT_CONSTRUCT(
        'run_id', v_run_id,
        'graph_run_id', v_graph_run_id,
        'status', 'SUCCEEDED',
        'task_count', v_task_count
    );
EXCEPTION
    WHEN OTHER THEN
        v_error_details := COALESCE(v_error_details, SQLERRM);

        IF (v_lock_acquired) THEN
            BEGIN
                SELECT COALESCE(MAX(GRAPH_RUN_GROUP_ID), :v_run_id)
                  INTO :v_graph_run_id
                  FROM
                  (
                      SELECT GRAPH_RUN_GROUP_ID
                      FROM TABLE(SKYPOINTS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
                          SCHEDULED_TIME_RANGE_START => :v_started_at,
                          SCHEDULED_TIME_RANGE_END => CURRENT_TIMESTAMP(),
                          TASK_NAME => 'TASK_MEMBER_INGESTION',
                          DATABASE_NAME => 'SKYPOINTS_DB',
                          SCHEMA_NAME => 'RAW',
                          RESULT_LIMIT => 1000
                      ))
                      WHERE GRAPH_RUN_GROUP_ID IS NOT NULL
                      QUALIFY ROW_NUMBER() OVER (ORDER BY SCHEDULED_TIME DESC) = 1
                  ) AS root_run;
            EXCEPTION
                WHEN OTHER THEN
                    v_graph_run_id := NULL;
            END;

            IF (v_graph_run_id IS NOT NULL AND v_graph_run_id <> v_run_id) THEN
                BEGIN
                    SELECT COUNT(*),
                           COALESCE(COUNT_IF(STATE = 'SUCCEEDED'), 0),
                           COALESCE(COUNT_IF(STATE IN ('FAILED', 'CANCELLED')), 0),
                           LISTAGG(IFF(STATE <> 'SUCCEEDED', NAME, NULL), ', ')
                               WITHIN GROUP (ORDER BY SCHEDULED_TIME),
                           LISTAGG(
                               IFF(STATE <> 'SUCCEEDED',
                                   NAME || '=' || STATE
                                       || COALESCE(': ' || ERROR_MESSAGE, ''),
                                   NULL),
                               '; '
                           ) WITHIN GROUP (ORDER BY SCHEDULED_TIME)
                      INTO :v_task_count, :v_success_count, :v_failed_task_count,
                           :v_failed_tasks, :v_task_errors
                      FROM TABLE(SKYPOINTS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
                          SCHEDULED_TIME_RANGE_START => :v_started_at,
                          SCHEDULED_TIME_RANGE_END => CURRENT_TIMESTAMP(),
                          DATABASE_NAME => 'SKYPOINTS_DB',
                          SCHEMA_NAME => 'RAW',
                          RESULT_LIMIT => 1000
                      ))
                     WHERE GRAPH_RUN_GROUP_ID = :v_graph_run_id
                       AND NAME IN
                       (
                           'TASK_MEMBER_INGESTION',
                           'TASK_REDEMPTION_INGESTION',
                           'TASK_INGESTION_VALIDATION',
                           'TASK_PARSE_AND_NORMALIZE',
                           'TASK_DQ_VALIDATION',
                           'TASK_MEMBER_PROCESSING',
                           'TASK_REDEMPTION_PROCESSING',
                           'TASK_COUNTRY_ROUTING',
                           'TASK_COUNTRY_RECONCILIATION'
                       );
                EXCEPTION
                    WHEN OTHER THEN
                        v_task_errors := 'Could not read failed task history: ' || SQLERRM;
                END;
            END IF;

            IF (v_graph_run_id IS NOT NULL AND v_graph_run_id <> v_run_id) THEN
                BEGIN
                    SELECT MAX(ERROR_DETAILS)
                      INTO :v_reconciliation_error
                      FROM SKYPOINTS_DB.AUDIT.COUNTRY_RECONCILIATION_AUDIT
                     WHERE RUN_ID = :v_graph_run_id
                       AND CHECK_NAME = 'RECONCILIATION_EXECUTION'
                       AND STATUS = 'FAILED';
                EXCEPTION
                    WHEN OTHER THEN
                        v_reconciliation_error :=
                            'Could not read reconciliation audit: ' || SQLERRM;
                END;
            END IF;

            IF (v_reconciliation_error IS NOT NULL) THEN
                v_task_errors := COALESCE(v_task_errors || '; ', '')
                    || 'COUNTRY_RECONCILIATION=' || v_reconciliation_error;
            END IF;

            IF (
                v_task_errors IS NOT NULL
                AND (
                    v_error_details IS NULL
                    OR v_task_errors <> v_error_details
                )
            ) THEN
                v_error_details := v_task_errors
                    || COALESCE(' | runner error: ' || v_error_details, '');
            END IF;

            BEGIN
                CALL SKYPOINTS_DB.AUDIT.SP_SUSPEND_PIPELINE_DESCENDANTS()
                  INTO :v_cleanup_errors;
            EXCEPTION
                WHEN OTHER THEN
                    v_cleanup_errors := 'Cleanup procedure failed: ' || SQLERRM;
            END;

            BEGIN
                UPDATE SKYPOINTS_DB.AUDIT.PIPELINE_RUN_AUDIT
                   SET GRAPH_RUN_ID = :v_graph_run_id,
                       STATUS = 'FAILED',
                       ENDED_AT = CURRENT_TIMESTAMP(),
                       TASK_COUNT = :v_task_count,
                       FAILED_TASKS = :v_failed_tasks,
                       ERROR_DETAILS = :v_error_details,
                       CLEANUP_ERRORS = :v_cleanup_errors
                 WHERE RUN_ID = :v_run_id;
            EXCEPTION
                WHEN OTHER THEN
                    v_cleanup_errors := COALESCE(v_cleanup_errors || '; ', '')
                        || 'Audit update failed: ' || SQLERRM;
            END;

            BEGIN
                UPDATE SKYPOINTS_DB.AUDIT.PIPELINE_RUN_CONTROL
                   SET STATUS = 'IDLE', ACTIVE_RUN_ID = NULL,
                       UPDATED_AT = CURRENT_TIMESTAMP()
                 WHERE CONTROL_NAME = 'PHASE3_6C'
                   AND ACTIVE_RUN_ID = :v_run_id;
                v_lock_acquired := FALSE;
            EXCEPTION
                WHEN OTHER THEN
                    v_cleanup_errors := COALESCE(v_cleanup_errors || '; ', '')
                        || 'Run lock release failed: ' || SQLERRM;
            END;
        ELSE
            UPDATE SKYPOINTS_DB.AUDIT.PIPELINE_RUN_AUDIT
               SET STATUS = 'FAILED',
                   ENDED_AT = CURRENT_TIMESTAMP(),
                   ERROR_DETAILS = :v_error_details
             WHERE RUN_ID = :v_run_id
               AND STATUS = 'STARTED';
        END IF;

        RAISE;
END;
$$;

-- Keep the manual root and all descendants suspended until the entry point is called.
ALTER TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_RECONCILIATION SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_PROCESSING SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_PROCESSING SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_DQ_VALIDATION SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_PARSE_AND_NORMALIZE SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION SUSPEND;
