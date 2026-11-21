-- Phase 6A: metadata-driven country routing.
-- Run after the Phase 3 task graph and Phase 4-5 processing deployment.

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG
(
    COUNTRY_CODE VARCHAR(3) NOT NULL,
    TARGET_TABLE VARCHAR NOT NULL,
    IS_ACTIVE BOOLEAN NOT NULL DEFAULT TRUE,
    CREATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    UPDATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    PRIMARY KEY (COUNTRY_CODE)
)
COMMENT = 'Approved ISO alpha-3 country-to-member-output routing configuration';

MERGE INTO SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG AS target
USING
(
    SELECT
        column1::VARCHAR(3) AS COUNTRY_CODE,
        'MEMBER_' || column1::VARCHAR AS TARGET_TABLE
    FROM VALUES
        ('USA'), ('IND'), ('GBR'), ('CAN'), ('AUS'),
        ('DEU'), ('FRA'), ('JPN'), ('SGP'), ('NZL'),
        ('ZAF'), ('BRA'), ('MEX'), ('ARE'), ('SAU'),
        ('KOR'), ('ITA'), ('ESP'), ('NLD'), ('CHE')
) AS source
ON target.COUNTRY_CODE = source.COUNTRY_CODE
WHEN NOT MATCHED THEN INSERT
(
    COUNTRY_CODE, TARGET_TABLE, IS_ACTIVE, CREATED_AT, UPDATED_AT
)
VALUES
(
    source.COUNTRY_CODE, source.TARGET_TABLE, TRUE,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_AUDIT
(
    RUN_ID VARCHAR NOT NULL,
    STARTED_AT TIMESTAMP_LTZ NOT NULL,
    ENDED_AT TIMESTAMP_LTZ,
    STATUS VARCHAR NOT NULL,
    TOTAL_MEMBERS NUMBER(38, 0) NOT NULL DEFAULT 0,
    ROUTED_MEMBERS NUMBER(38, 0) NOT NULL DEFAULT 0,
    INSERTED_COUNT NUMBER(38, 0) NOT NULL DEFAULT 0,
    UPDATED_COUNT NUMBER(38, 0) NOT NULL DEFAULT 0,
    REMOVED_COUNT NUMBER(38, 0) NOT NULL DEFAULT 0,
    QUARANTINED_COUNT NUMBER(38, 0) NOT NULL DEFAULT 0,
    ERROR_DETAILS VARCHAR,
    PRIMARY KEY (RUN_ID)
)
COMMENT = 'Per-execution country routing audit and operation counts';

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.CORE.SP_ROUTE_MEMBERS_BY_COUNTRY()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    e_invalid_country_config EXCEPTION
        (-20006, 'Country routing configuration failed integrity validation');
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_total_members NUMBER(38, 0) DEFAULT 0;
    v_routed_members NUMBER(38, 0) DEFAULT 0;
    v_inserted_count NUMBER(38, 0) DEFAULT 0;
    v_updated_count NUMBER(38, 0) DEFAULT 0;
    v_removed_count NUMBER(38, 0) DEFAULT 0;
    v_quarantined_count NUMBER(38, 0) DEFAULT 0;
    v_duplicate_config_count NUMBER(38, 0) DEFAULT 0;
    v_missing_config_count NUMBER(38, 0) DEFAULT 0;
    v_unapproved_config_count NUMBER(38, 0) DEFAULT 0;
    v_invalid_target_count NUMBER(38, 0) DEFAULT 0;
    v_config_error VARCHAR;
    v_country_code VARCHAR(3);
    v_target_table VARCHAR;
    v_target_fqn VARCHAR;
    v_table_exists NUMBER(38, 0) DEFAULT 0;
    v_country_members NUMBER(38, 0) DEFAULT 0;
    v_country_inserts NUMBER(38, 0) DEFAULT 0;
    v_country_updates NUMBER(38, 0) DEFAULT 0;
    v_country_removals NUMBER(38, 0) DEFAULT 0;
    v_transaction_started BOOLEAN DEFAULT FALSE;
BEGIN
    SELECT COALESCE(
        SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'),
        UUID_STRING()
    )
      INTO :v_run_id;

    MERGE INTO SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_AUDIT AS target
    USING (SELECT :v_run_id AS RUN_ID) AS source
       ON target.RUN_ID = source.RUN_ID
    WHEN MATCHED THEN UPDATE SET
        STARTED_AT = :v_started_at,
        ENDED_AT = NULL,
        STATUS = 'STARTED',
        TOTAL_MEMBERS = 0,
        ROUTED_MEMBERS = 0,
        INSERTED_COUNT = 0,
        UPDATED_COUNT = 0,
        REMOVED_COUNT = 0,
        QUARANTINED_COUNT = 0,
        ERROR_DETAILS = NULL
    WHEN NOT MATCHED THEN INSERT
    (
        RUN_ID, STARTED_AT, STATUS, TOTAL_MEMBERS, ROUTED_MEMBERS,
        INSERTED_COUNT, UPDATED_COUNT, REMOVED_COUNT, QUARANTINED_COUNT
    )
    VALUES
    (
        source.RUN_ID, :v_started_at, 'STARTED', 0, 0, 0, 0, 0, 0
    );

    SELECT COUNT(*)
      INTO :v_duplicate_config_count
      FROM
      (
          SELECT COUNTRY_CODE
          FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG
          GROUP BY COUNTRY_CODE
          HAVING COUNT(*) > 1
      ) AS duplicate_codes;

    SELECT COUNT(*)
      INTO :v_missing_config_count
      FROM VALUES
          ('USA'), ('IND'), ('GBR'), ('CAN'), ('AUS'),
          ('DEU'), ('FRA'), ('JPN'), ('SGP'), ('NZL'),
          ('ZAF'), ('BRA'), ('MEX'), ('ARE'), ('SAU'),
          ('KOR'), ('ITA'), ('ESP'), ('NLD'), ('CHE')
          AS expected(COUNTRY_CODE)
     WHERE NOT EXISTS
     (
         SELECT 1
         FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG AS configured
         WHERE configured.COUNTRY_CODE = expected.COUNTRY_CODE
     );

    SELECT COUNT(*)
      INTO :v_unapproved_config_count
      FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG
     WHERE COUNTRY_CODE IS NULL
        OR COUNTRY_CODE NOT IN
        (
            'USA', 'IND', 'GBR', 'CAN', 'AUS', 'DEU', 'FRA', 'JPN', 'SGP', 'NZL',
            'ZAF', 'BRA', 'MEX', 'ARE', 'SAU', 'KOR', 'ITA', 'ESP', 'NLD', 'CHE'
        );

    SELECT COUNT(*)
      INTO :v_invalid_target_count
      FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG
     WHERE TARGET_TABLE IS DISTINCT FROM ('MEMBER_' || COUNTRY_CODE);

    IF (
        v_duplicate_config_count > 0
        OR v_missing_config_count > 0
        OR v_unapproved_config_count > 0
        OR v_invalid_target_count > 0
    ) THEN
        v_config_error :=
            'Country routing configuration validation failed: duplicate_country_codes='
            || v_duplicate_config_count
            || ', missing_approved_countries='
            || v_missing_config_count
            || ', unapproved_country_codes='
            || v_unapproved_config_count
            || ', invalid_target_table_names='
            || v_invalid_target_count;
        RAISE e_invalid_country_config;
    END IF;

    CREATE OR REPLACE TEMPORARY TABLE SKYPOINTS_DB.CORE.COUNTRY_ROUTING_DECISIONS AS
    WITH current_members AS
    (
        SELECT
            member.*,
            NULLIF(UPPER(TRIM(member.COUNTRY)), '') AS NORMALIZED_COUNTRY
        FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT AS member
    )
    SELECT
        current_members.MEMBER_ID,
        current_members.NORMALIZED_COUNTRY,
        CASE
            WHEN current_members.NORMALIZED_COUNTRY IS NULL
                THEN 'MISSING_COUNTRY'
            WHEN config.COUNTRY_CODE IS NULL
                THEN 'UNSUPPORTED_COUNTRY'
            WHEN NOT config.IS_ACTIVE
                THEN 'INACTIVE_COUNTRY'
            ELSE NULL
        END AS FAILURE_REASON,
        current_members.SOURCE_RECORD,
        current_members.SOURCE_FILENAME,
        current_members.SOURCE_ROW_NUMBER,
        current_members.SOURCE_FILE_CONTENT_KEY,
        OBJECT_CONSTRUCT_KEEP_NULL
        (
            'MEMBER_ID', current_members.MEMBER_ID,
            'MEMBER_NAME', current_members.MEMBER_NAME,
            'ENROLLMENT_DATE', current_members.ENROLLMENT_DATE,
            'LAST_FLIGHT_DATE', current_members.LAST_FLIGHT_DATE,
            'TIER_CODE', current_members.TIER_CODE,
            'AGENT_NAME', current_members.AGENT_NAME,
            'STATE', current_members.STATE,
            'COUNTRY', current_members.COUNTRY,
            'DOB', current_members.DOB,
            'IS_ACTIVE', current_members.IS_ACTIVE,
            'POST_CODE', current_members.POST_CODE,
            'AGE', current_members.AGE,
            'STALE_MEMBER', current_members.STALE_MEMBER,
            'SOURCE_FILENAME', current_members.SOURCE_FILENAME,
            'SOURCE_ROW_NUMBER', current_members.SOURCE_ROW_NUMBER,
            'SOURCE_FILE_CONTENT_KEY', current_members.SOURCE_FILE_CONTENT_KEY,
            'INGESTED_AT', current_members.INGESTED_AT,
            'SOURCE_RECORD', current_members.SOURCE_RECORD,
            'LAST_PROCESSED_RUN_ID', current_members.LAST_PROCESSED_RUN_ID,
            'UPDATED_AT', current_members.UPDATED_AT
        ) AS ORIGINAL_MEMBER_DATA
    FROM current_members
    LEFT JOIN SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG AS config
      ON config.COUNTRY_CODE = current_members.NORMALIZED_COUNTRY
     AND config.COUNTRY_CODE IN
     (
        'USA', 'IND', 'GBR', 'CAN', 'AUS', 'DEU', 'FRA', 'JPN', 'SGP', 'NZL',
        'ZAF', 'BRA', 'MEX', 'ARE', 'SAU', 'KOR', 'ITA', 'ESP', 'NLD', 'CHE'
     );

    SELECT COUNT(*), COALESCE(COUNT_IF(FAILURE_REASON IS NOT NULL), 0)
      INTO :v_total_members, :v_quarantined_count
      FROM SKYPOINTS_DB.CORE.COUNTRY_ROUTING_DECISIONS;

    MERGE INTO SKYPOINTS_DB.STAGING.DQ_QUARANTINE AS target
    USING
    (
        SELECT
            :v_run_id AS RUN_ID,
            'MEMBER_ROUTING' AS DATASET_NAME,
            SHA2(TO_JSON(ARRAY_CONSTRUCT(
                MEMBER_ID, NORMALIZED_COUNTRY, FAILURE_REASON
            )), 256) AS RECORD_KEY,
            SOURCE_FILENAME,
            SOURCE_ROW_NUMBER,
            SOURCE_FILE_CONTENT_KEY,
            SOURCE_RECORD AS ORIGINAL_RECORD,
            ORIGINAL_MEMBER_DATA AS ORIGINAL_PAYLOAD,
            NULL::NUMBER(38, 0) AS TRANSACTION_INDEX,
            ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
                'rule_id', FAILURE_REASON,
                'rule_name', 'Country routing validation',
                'message', FAILURE_REASON
            )) AS FAILURE_REASONS
        FROM SKYPOINTS_DB.CORE.COUNTRY_ROUTING_DECISIONS
        WHERE FAILURE_REASON IS NOT NULL
    ) AS source
       ON target.DATASET_NAME = source.DATASET_NAME
      AND target.RECORD_KEY = source.RECORD_KEY
    WHEN MATCHED THEN UPDATE SET
        RUN_ID = source.RUN_ID,
        SOURCE_FILENAME = source.SOURCE_FILENAME,
        SOURCE_ROW_NUMBER = source.SOURCE_ROW_NUMBER,
        SOURCE_FILE_CONTENT_KEY = source.SOURCE_FILE_CONTENT_KEY,
        ORIGINAL_RECORD = source.ORIGINAL_RECORD,
        ORIGINAL_PAYLOAD = source.ORIGINAL_PAYLOAD,
        FAILURE_REASONS = source.FAILURE_REASONS,
        QUARANTINED_AT = CURRENT_TIMESTAMP()
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

    -- Create only tables for active, allowlisted countries with current members.
    FOR route_country IN
    (
        SELECT config.COUNTRY_CODE, config.TARGET_TABLE
        FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG AS config
        JOIN SKYPOINTS_DB.CORE.COUNTRY_ROUTING_DECISIONS AS decisions
          ON decisions.NORMALIZED_COUNTRY = config.COUNTRY_CODE
         AND decisions.FAILURE_REASON IS NULL
        WHERE config.IS_ACTIVE
          AND config.COUNTRY_CODE IN
          (
            'USA', 'IND', 'GBR', 'CAN', 'AUS', 'DEU', 'FRA', 'JPN', 'SGP', 'NZL',
            'ZAF', 'BRA', 'MEX', 'ARE', 'SAU', 'KOR', 'ITA', 'ESP', 'NLD', 'CHE'
          )
          AND config.TARGET_TABLE = 'MEMBER_' || config.COUNTRY_CODE
        GROUP BY config.COUNTRY_CODE, config.TARGET_TABLE
    )
    DO
        v_country_code := route_country.COUNTRY_CODE;
        v_target_table := route_country.TARGET_TABLE;
        v_target_fqn := 'SKYPOINTS_DB.CORE.' || v_target_table;

        CREATE TABLE IF NOT EXISTS IDENTIFIER(:v_target_fqn)
            LIKE SKYPOINTS_DB.CORE.MEMBER_CURRENT;
    END FOR;

    BEGIN TRANSACTION;
    v_transaction_started := TRUE;

    FOR route_country IN
    (
        SELECT config.COUNTRY_CODE, config.TARGET_TABLE
        FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG AS config
        JOIN SKYPOINTS_DB.CORE.COUNTRY_ROUTING_DECISIONS AS decisions
          ON decisions.NORMALIZED_COUNTRY = config.COUNTRY_CODE
         AND decisions.FAILURE_REASON IS NULL
        WHERE config.IS_ACTIVE
          AND config.COUNTRY_CODE IN
          (
            'USA', 'IND', 'GBR', 'CAN', 'AUS', 'DEU', 'FRA', 'JPN', 'SGP', 'NZL',
            'ZAF', 'BRA', 'MEX', 'ARE', 'SAU', 'KOR', 'ITA', 'ESP', 'NLD', 'CHE'
          )
          AND config.TARGET_TABLE = 'MEMBER_' || config.COUNTRY_CODE
        GROUP BY config.COUNTRY_CODE, config.TARGET_TABLE
    )
    DO
        v_country_code := route_country.COUNTRY_CODE;
        v_target_table := route_country.TARGET_TABLE;
        v_target_fqn := 'SKYPOINTS_DB.CORE.' || v_target_table;

        SELECT COUNT(*)
          INTO :v_country_members
          FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT
         WHERE UPPER(TRIM(COUNTRY)) = :v_country_code;

        SELECT
            COALESCE(COUNT_IF(target.MEMBER_ID IS NULL), 0),
            COALESCE(COUNT_IF(
                target.MEMBER_ID IS NOT NULL
                AND
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
                    OR target.LAST_PROCESSED_RUN_ID IS DISTINCT FROM source.LAST_PROCESSED_RUN_ID
                    OR target.UPDATED_AT IS DISTINCT FROM source.UPDATED_AT
                )
            ), 0)
          INTO :v_country_inserts, :v_country_updates
          FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT AS source
          LEFT JOIN IDENTIFIER(:v_target_fqn) AS target
            ON target.MEMBER_ID = source.MEMBER_ID
         WHERE UPPER(TRIM(source.COUNTRY)) = :v_country_code;

        MERGE INTO IDENTIFIER(:v_target_fqn) AS target
        USING
        (
            SELECT *
            FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT
            WHERE UPPER(TRIM(COUNTRY)) = :v_country_code
        ) AS source
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
            OR target.LAST_PROCESSED_RUN_ID IS DISTINCT FROM source.LAST_PROCESSED_RUN_ID
            OR target.UPDATED_AT IS DISTINCT FROM source.UPDATED_AT
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
            LAST_PROCESSED_RUN_ID = source.LAST_PROCESSED_RUN_ID,
            UPDATED_AT = source.UPDATED_AT
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
            source.SOURCE_FILE_CONTENT_KEY, source.INGESTED_AT,
            source.SOURCE_RECORD, source.LAST_PROCESSED_RUN_ID, source.UPDATED_AT
        );

        v_routed_members := v_routed_members + v_country_members;
        v_inserted_count := v_inserted_count + v_country_inserts;
        v_updated_count := v_updated_count + v_country_updates;
    END FOR;

    -- All valid destinations are merged before stale country rows are removed.
    -- Both operations share this transaction, so merge failures preserve old rows.
    FOR configured_country IN
    (
        SELECT COUNTRY_CODE, TARGET_TABLE
        FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG
        WHERE COUNTRY_CODE IN
        (
            'USA', 'IND', 'GBR', 'CAN', 'AUS', 'DEU', 'FRA', 'JPN', 'SGP', 'NZL',
            'ZAF', 'BRA', 'MEX', 'ARE', 'SAU', 'KOR', 'ITA', 'ESP', 'NLD', 'CHE'
        )
          AND TARGET_TABLE = 'MEMBER_' || COUNTRY_CODE
    )
    DO
        v_country_code := configured_country.COUNTRY_CODE;
        v_target_table := configured_country.TARGET_TABLE;
        v_target_fqn := 'SKYPOINTS_DB.CORE.' || v_target_table;

        SELECT COUNT(*)
          INTO :v_table_exists
          FROM SKYPOINTS_DB.INFORMATION_SCHEMA.TABLES
         WHERE TABLE_SCHEMA = 'CORE'
           AND TABLE_NAME = :v_target_table
           AND TABLE_TYPE = 'BASE TABLE';

        IF (v_table_exists > 0) THEN
            SELECT COUNT(*)
              INTO :v_country_removals
              FROM IDENTIFIER(:v_target_fqn)
             WHERE MEMBER_ID NOT IN
                   (SELECT MEMBER_ID FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT)
                OR MEMBER_ID IN
                   (
                       SELECT MEMBER_ID
                       FROM SKYPOINTS_DB.CORE.COUNTRY_ROUTING_DECISIONS
                       WHERE FAILURE_REASON IS NULL
                         AND NORMALIZED_COUNTRY IS DISTINCT FROM :v_country_code
                   );

            DELETE FROM IDENTIFIER(:v_target_fqn)
             WHERE MEMBER_ID NOT IN
                   (SELECT MEMBER_ID FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT)
                OR MEMBER_ID IN
                   (
                       SELECT MEMBER_ID
                       FROM SKYPOINTS_DB.CORE.COUNTRY_ROUTING_DECISIONS
                       WHERE FAILURE_REASON IS NULL
                         AND NORMALIZED_COUNTRY IS DISTINCT FROM :v_country_code
                   );

            v_removed_count := v_removed_count + v_country_removals;
        END IF;
    END FOR;

    COMMIT;
    v_transaction_started := FALSE;

    UPDATE SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_AUDIT
       SET ENDED_AT = CURRENT_TIMESTAMP(),
           STATUS = 'SUCCEEDED',
           TOTAL_MEMBERS = :v_total_members,
           ROUTED_MEMBERS = :v_routed_members,
           INSERTED_COUNT = :v_inserted_count,
           UPDATED_COUNT = :v_updated_count,
           REMOVED_COUNT = :v_removed_count,
           QUARANTINED_COUNT = :v_quarantined_count
     WHERE RUN_ID = :v_run_id;

    RETURN OBJECT_CONSTRUCT(
        'run_id', v_run_id,
        'total_members', v_total_members,
        'routed_members', v_routed_members,
        'inserted_count', v_inserted_count,
        'updated_count', v_updated_count,
        'removed_count', v_removed_count,
        'quarantined_count', v_quarantined_count
    );
EXCEPTION
    WHEN OTHER THEN
        IF (v_transaction_started) THEN
            ROLLBACK;
            v_transaction_started := FALSE;
            v_routed_members := 0;
            v_inserted_count := 0;
            v_updated_count := 0;
            v_removed_count := 0;
        END IF;
        UPDATE SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_AUDIT
           SET ENDED_AT = CURRENT_TIMESTAMP(),
               STATUS = 'FAILED',
               TOTAL_MEMBERS = :v_total_members,
               ROUTED_MEMBERS = :v_routed_members,
               INSERTED_COUNT = :v_inserted_count,
               UPDATED_COUNT = :v_updated_count,
               REMOVED_COUNT = :v_removed_count,
               QUARANTINED_COUNT = :v_quarantined_count,
               ERROR_DETAILS = COALESCE(:v_config_error, :SQLERRM)
         WHERE RUN_ID = :v_run_id;
        RAISE;
END;
$$;

CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING
    WAREHOUSE = 'SKYPOINTS_ETL_WH'
    COMMENT = 'Route valid current members to approved country output tables'
    AFTER SKYPOINTS_DB.RAW.TASK_REDEMPTION_PROCESSING
AS
    CALL SKYPOINTS_DB.CORE.SP_ROUTE_MEMBERS_BY_COUNTRY();

-- Keep the complete graph dormant after deployment.
ALTER TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_PROCESSING SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_PROCESSING SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_DQ_VALIDATION SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_PARSE_AND_NORMALIZE SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION SUSPEND;
ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION SUSPEND;
