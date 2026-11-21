-- Phase 6B-6C: per-member movement audit and country-output reconciliation.
-- Run after deploy_country_routing.sql with the same task-owning role.

CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.COUNTRY_RECONCILIATION_AUDIT
(
    RUN_ID VARCHAR NOT NULL,
    CHECK_NAME VARCHAR NOT NULL,
    STATUS VARCHAR NOT NULL,
    FAILURE_COUNT NUMBER(38, 0) NOT NULL,
    ERROR_DETAILS VARCHAR,
    EXECUTED_AT TIMESTAMP_LTZ NOT NULL,
    PRIMARY KEY (RUN_ID, CHECK_NAME)
)
COMMENT = 'Persistent per-check results from country-output reconciliation';

CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.AUDIT.SP_VALIDATE_COUNTRY_ROUTING()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    v_country_code VARCHAR(3);
    v_target_table VARCHAR;
    v_target_fqn VARCHAR;
    v_table_exists NUMBER(38, 0) DEFAULT 0;
    v_member_id_column_count NUMBER(38, 0) DEFAULT 0;
    v_duplicate_config_count NUMBER(38, 0) DEFAULT 0;
    v_missing_config_count NUMBER(38, 0) DEFAULT 0;
    v_unapproved_config_count NUMBER(38, 0) DEFAULT 0;
    v_invalid_target_count NUMBER(38, 0) DEFAULT 0;
    v_null_active_count NUMBER(38, 0) DEFAULT 0;
    v_unapproved_table_count NUMBER(38, 0) DEFAULT 0;
    v_missing_route_count NUMBER(38, 0) DEFAULT 0;
    v_duplicate_route_count NUMBER(38, 0) DEFAULT 0;
    v_wrong_country_count NUMBER(38, 0) DEFAULT 0;
    v_invalid_destination_route_count NUMBER(38, 0) DEFAULT 0;
    v_schema_difference_count NUMBER(38, 0) DEFAULT 0;
    v_failed_check_count NUMBER(38, 0) DEFAULT 0;
    v_overall_status VARCHAR;
    c_approved_country_tables CURSOR FOR
        SELECT
            column1::VARCHAR(3) AS COUNTRY_CODE,
            'MEMBER_' || column1::VARCHAR AS TARGET_TABLE
        FROM VALUES
            ('USA'), ('IND'), ('GBR'), ('CAN'), ('AUS'),
            ('DEU'), ('FRA'), ('JPN'), ('SGP'), ('NZL'),
            ('ZAF'), ('BRA'), ('MEX'), ('ARE'), ('SAU'),
            ('KOR'), ('ITA'), ('ESP'), ('NLD'), ('CHE');
BEGIN
    SELECT COALESCE(
        SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'),
        UUID_STRING()
    )
      INTO :v_run_id;

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

    SELECT COUNT(*)
      INTO :v_null_active_count
      FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG
     WHERE IS_ACTIVE IS NULL;

    CREATE OR REPLACE TEMPORARY TABLE SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_ROUTED
    (
        MEMBER_ID VARCHAR,
        COUNTRY_CODE VARCHAR(3) NOT NULL
    );

    OPEN c_approved_country_tables;
    FETCH c_approved_country_tables INTO v_country_code, v_target_table;
    WHILE (v_country_code IS NOT NULL) DO
        v_target_fqn := 'SKYPOINTS_DB.CORE.' || v_target_table;

        SELECT COUNT(*)
          INTO :v_table_exists
          FROM SKYPOINTS_DB.INFORMATION_SCHEMA.TABLES
         WHERE TABLE_SCHEMA = 'CORE'
           AND TABLE_NAME = :v_target_table
           AND TABLE_TYPE = 'BASE TABLE';

        SELECT COUNT(*)
          INTO :v_member_id_column_count
          FROM SKYPOINTS_DB.INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_SCHEMA = 'CORE'
           AND TABLE_NAME = :v_target_table
           AND COLUMN_NAME = 'MEMBER_ID';

        IF (v_table_exists > 0 AND v_member_id_column_count > 0) THEN
            INSERT INTO SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_ROUTED
            (
                MEMBER_ID, COUNTRY_CODE
            )
            SELECT TO_VARCHAR(MEMBER_ID), :v_country_code
            FROM IDENTIFIER(:v_target_fqn);
        END IF;

        FETCH c_approved_country_tables INTO v_country_code, v_target_table;
    END WHILE;
    CLOSE c_approved_country_tables;

    CREATE OR REPLACE TEMPORARY TABLE SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_MEMBER_STATUS AS
    SELECT
        member.MEMBER_ID,
        NULLIF(UPPER(TRIM(member.COUNTRY)), '') AS COUNTRY_CODE,
        IFF(
            EXISTS
            (
                SELECT 1
                FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG AS config
                WHERE config.COUNTRY_CODE = UPPER(TRIM(member.COUNTRY))
                  AND config.IS_ACTIVE
                  AND config.COUNTRY_CODE IN
                  (
                      'USA', 'IND', 'GBR', 'CAN', 'AUS', 'DEU', 'FRA', 'JPN', 'SGP', 'NZL',
                      'ZAF', 'BRA', 'MEX', 'ARE', 'SAU', 'KOR', 'ITA', 'ESP', 'NLD', 'CHE'
                  )
            ),
            TRUE,
            FALSE
        ) AS HAS_VALID_DESTINATION
    FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT AS member;

    CREATE OR REPLACE TEMPORARY TABLE SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_VALID_CURRENT AS
    SELECT MEMBER_ID, COUNTRY_CODE
    FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_MEMBER_STATUS
    WHERE HAS_VALID_DESTINATION;

    CREATE OR REPLACE TEMPORARY TABLE SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_PRESERVED AS
    WITH invalid_destinations AS
    (
        SELECT MEMBER_ID, COUNTRY_CODE
        FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_MEMBER_STATUS
        WHERE NOT HAS_VALID_DESTINATION
    ),
    latest_quarantined_movements AS
    (
        SELECT
            movement.MEMBER_ID,
            movement.PREVIOUS_COUNTRY
        FROM SKYPOINTS_DB.AUDIT.COUNTRY_MOVEMENT_AUDIT AS movement
        JOIN invalid_destinations AS invalid
          ON invalid.MEMBER_ID = movement.MEMBER_ID
         AND invalid.COUNTRY_CODE IS NOT DISTINCT FROM movement.DESTINATION_COUNTRY
        WHERE movement.ACTION = 'QUARANTINED'
          AND movement.STATUS = 'QUARANTINED'
        QUALIFY ROW_NUMBER() OVER
        (
            PARTITION BY movement.MEMBER_ID
            ORDER BY
                IFF(movement.RUN_ID = :v_run_id, 1, 0) DESC,
                movement.UPDATED_AT DESC
        ) = 1
    )
    SELECT DISTINCT
        movement.MEMBER_ID,
        UPPER(TRIM(previous_country.VALUE::VARCHAR)) AS PREVIOUS_COUNTRY
    FROM latest_quarantined_movements AS movement,
         LATERAL SPLIT_TO_TABLE(movement.PREVIOUS_COUNTRY, ',') AS previous_country
    WHERE previous_country.VALUE IS NOT NULL;

    SELECT COUNT(*)
      INTO :v_missing_route_count
      FROM
      (
          SELECT current_member.MEMBER_ID
          FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_VALID_CURRENT AS current_member
          LEFT JOIN SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_ROUTED AS routed
            ON routed.MEMBER_ID = current_member.MEMBER_ID
          GROUP BY current_member.MEMBER_ID, current_member.COUNTRY_CODE
          HAVING COUNT(routed.MEMBER_ID) <> 1
              OR COALESCE(COUNT_IF(
                    routed.COUNTRY_CODE = current_member.COUNTRY_CODE
                 ), 0) <> 1
      ) AS missing_or_misrouted_members;

    SELECT COUNT(*)
      INTO :v_duplicate_route_count
      FROM
      (
          SELECT MEMBER_ID
          FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_ROUTED
          GROUP BY MEMBER_ID
          HAVING COUNT(*) > 1
      ) AS duplicate_members;

    SELECT COUNT(*)
      INTO :v_wrong_country_count
      FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_ROUTED AS routed
      LEFT JOIN SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_MEMBER_STATUS AS member
        ON member.MEMBER_ID = routed.MEMBER_ID
     WHERE member.MEMBER_ID IS NULL
        OR
        (
            member.HAS_VALID_DESTINATION
            AND routed.COUNTRY_CODE IS DISTINCT FROM member.COUNTRY_CODE
        )
        OR
        (
            NOT member.HAS_VALID_DESTINATION
            AND NOT EXISTS
            (
                SELECT 1
                FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_PRESERVED AS preserved
                WHERE preserved.MEMBER_ID = routed.MEMBER_ID
                  AND preserved.PREVIOUS_COUNTRY = routed.COUNTRY_CODE
            )
        );

    SELECT COUNT(*)
      INTO :v_invalid_destination_route_count
      FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_ROUTED AS routed
      JOIN SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_MEMBER_STATUS AS member
        ON member.MEMBER_ID = routed.MEMBER_ID
     WHERE NOT member.HAS_VALID_DESTINATION
       AND NOT EXISTS
       (
           SELECT 1
           FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_PRESERVED AS preserved
           WHERE preserved.MEMBER_ID = routed.MEMBER_ID
             AND preserved.PREVIOUS_COUNTRY = routed.COUNTRY_CODE
       );

    SELECT COUNT(*)
      INTO :v_unapproved_table_count
      FROM SKYPOINTS_DB.INFORMATION_SCHEMA.TABLES AS tables
     WHERE tables.TABLE_SCHEMA = 'CORE'
       AND tables.TABLE_TYPE = 'BASE TABLE'
       AND STARTSWITH(tables.TABLE_NAME, 'MEMBER_')
       AND tables.TABLE_NAME NOT IN ('MEMBER_CURRENT', 'MEMBER_HISTORY')
       AND tables.TABLE_NAME NOT IN
       (
           SELECT 'MEMBER_' || column1::VARCHAR
           FROM VALUES
               ('USA'), ('IND'), ('GBR'), ('CAN'), ('AUS'),
               ('DEU'), ('FRA'), ('JPN'), ('SGP'), ('NZL'),
               ('ZAF'), ('BRA'), ('MEX'), ('ARE'), ('SAU'),
               ('KOR'), ('ITA'), ('ESP'), ('NLD'), ('CHE')
       );

    CREATE OR REPLACE TEMPORARY TABLE SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_SCHEMA_DIFFERENCES AS
    WITH approved_codes AS
    (
        SELECT column1::VARCHAR(3) AS COUNTRY_CODE
        FROM VALUES
            ('USA'), ('IND'), ('GBR'), ('CAN'), ('AUS'),
            ('DEU'), ('FRA'), ('JPN'), ('SGP'), ('NZL'),
            ('ZAF'), ('BRA'), ('MEX'), ('ARE'), ('SAU'),
            ('KOR'), ('ITA'), ('ESP'), ('NLD'), ('CHE')
    ),
    country_tables AS
    (
        SELECT tables.TABLE_NAME
        FROM SKYPOINTS_DB.INFORMATION_SCHEMA.TABLES AS tables
        WHERE tables.TABLE_SCHEMA = 'CORE'
          AND tables.TABLE_TYPE = 'BASE TABLE'
          AND tables.TABLE_NAME IN
          (
              SELECT 'MEMBER_' || COUNTRY_CODE
              FROM approved_codes
          )
    ),
    expected_columns AS
    (
        SELECT
            COLUMN_NAME,
            DATA_TYPE,
            CHARACTER_MAXIMUM_LENGTH,
            NUMERIC_PRECISION,
            NUMERIC_SCALE,
            DATETIME_PRECISION,
            IS_NULLABLE,
            ORDINAL_POSITION
        FROM SKYPOINTS_DB.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'CORE'
          AND TABLE_NAME = 'MEMBER_CURRENT'
    ),
    actual_columns AS
    (
        SELECT
            columns.TABLE_NAME,
            columns.COLUMN_NAME,
            columns.DATA_TYPE,
            columns.CHARACTER_MAXIMUM_LENGTH,
            columns.NUMERIC_PRECISION,
            columns.NUMERIC_SCALE,
            columns.DATETIME_PRECISION,
            columns.IS_NULLABLE,
            columns.ORDINAL_POSITION
        FROM SKYPOINTS_DB.INFORMATION_SCHEMA.COLUMNS AS columns
        JOIN country_tables
          ON country_tables.TABLE_NAME = columns.TABLE_NAME
        WHERE columns.TABLE_SCHEMA = 'CORE'
    )
    SELECT country_tables.TABLE_NAME, expected_columns.COLUMN_NAME
    FROM country_tables
    CROSS JOIN expected_columns
    LEFT JOIN actual_columns
      ON actual_columns.TABLE_NAME = country_tables.TABLE_NAME
     AND actual_columns.COLUMN_NAME = expected_columns.COLUMN_NAME
    WHERE actual_columns.COLUMN_NAME IS NULL
       OR actual_columns.DATA_TYPE IS DISTINCT FROM expected_columns.DATA_TYPE
       OR actual_columns.CHARACTER_MAXIMUM_LENGTH IS DISTINCT FROM expected_columns.CHARACTER_MAXIMUM_LENGTH
       OR actual_columns.NUMERIC_PRECISION IS DISTINCT FROM expected_columns.NUMERIC_PRECISION
       OR actual_columns.NUMERIC_SCALE IS DISTINCT FROM expected_columns.NUMERIC_SCALE
       OR actual_columns.DATETIME_PRECISION IS DISTINCT FROM expected_columns.DATETIME_PRECISION
       OR actual_columns.IS_NULLABLE IS DISTINCT FROM expected_columns.IS_NULLABLE
       OR actual_columns.ORDINAL_POSITION IS DISTINCT FROM expected_columns.ORDINAL_POSITION
    UNION ALL
    SELECT actual_columns.TABLE_NAME, actual_columns.COLUMN_NAME
    FROM actual_columns
    LEFT JOIN expected_columns
      ON expected_columns.COLUMN_NAME = actual_columns.COLUMN_NAME
    WHERE expected_columns.COLUMN_NAME IS NULL;

    SELECT COUNT(*)
      INTO :v_schema_difference_count
      FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_SCHEMA_DIFFERENCES;

    CREATE OR REPLACE TEMPORARY TABLE SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_CHECKS
    (
        CHECK_NAME VARCHAR NOT NULL,
        STATUS VARCHAR NOT NULL,
        FAILURE_COUNT NUMBER(38, 0) NOT NULL,
        ERROR_DETAILS VARCHAR
    );

    INSERT INTO SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_CHECKS
    (
        CHECK_NAME, STATUS, FAILURE_COUNT, ERROR_DETAILS
    )
    VALUES
    (
        'VALID_MEMBERS_EXACTLY_ONCE',
        IFF(:v_missing_route_count = 0, 'PASSED', 'FAILED'),
        :v_missing_route_count,
        'valid_member_routing_discrepancies=' || :v_missing_route_count
    ),
    (
        'NO_DUPLICATE_COUNTRY_MEMBERS',
        IFF(:v_duplicate_route_count = 0, 'PASSED', 'FAILED'),
        :v_duplicate_route_count,
        'members_in_multiple_country_rows=' || :v_duplicate_route_count
    ),
    (
        'NO_WRONG_COUNTRY_ROWS',
        IFF(:v_wrong_country_count = 0, 'PASSED', 'FAILED'),
        :v_wrong_country_count,
        'orphan_or_wrong_country_or_unpreserved_invalid_rows=' || :v_wrong_country_count
    ),
    (
        'NO_INVALID_DESTINATIONS_ROUTED',
        IFF(:v_invalid_destination_route_count = 0, 'PASSED', 'FAILED'),
        :v_invalid_destination_route_count,
        'unpreserved_invalid_destination_rows=' || :v_invalid_destination_route_count
    ),
    (
        'ONLY_APPROVED_COUNTRY_TABLES',
        IFF(:v_unapproved_table_count = 0, 'PASSED', 'FAILED'),
        :v_unapproved_table_count,
        'unapproved_country_tables=' || :v_unapproved_table_count
    ),
    (
        'COUNTRY_ROUTING_CONFIGURATION_VALID',
        IFF(
            :v_duplicate_config_count + :v_missing_config_count
                + :v_unapproved_config_count + :v_invalid_target_count
                + :v_null_active_count = 0,
            'PASSED',
            'FAILED'
        ),
        :v_duplicate_config_count + :v_missing_config_count
            + :v_unapproved_config_count + :v_invalid_target_count
            + :v_null_active_count,
        'duplicate_codes=' || :v_duplicate_config_count
            || ', missing_approved_codes=' || :v_missing_config_count
            || ', unapproved_codes=' || :v_unapproved_config_count
            || ', invalid_target_names=' || :v_invalid_target_count
            || ', null_is_active_values=' || :v_null_active_count
    ),
    (
        'COUNTRY_TABLE_SCHEMA_COMPATIBLE',
        IFF(:v_schema_difference_count = 0, 'PASSED', 'FAILED'),
        :v_schema_difference_count,
        'column_schema_differences=' || :v_schema_difference_count
    );

    MERGE INTO SKYPOINTS_DB.AUDIT.COUNTRY_RECONCILIATION_AUDIT AS target
    USING
    (
        SELECT
            :v_run_id AS RUN_ID,
            CHECK_NAME,
            STATUS,
            FAILURE_COUNT,
            ERROR_DETAILS
        FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_CHECKS
    ) AS source
       ON target.RUN_ID = source.RUN_ID
      AND target.CHECK_NAME = source.CHECK_NAME
    WHEN MATCHED THEN UPDATE SET
        STATUS = source.STATUS,
        FAILURE_COUNT = source.FAILURE_COUNT,
        ERROR_DETAILS = source.ERROR_DETAILS,
        EXECUTED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
    (
        RUN_ID, CHECK_NAME, STATUS, FAILURE_COUNT, ERROR_DETAILS, EXECUTED_AT
    )
    VALUES
    (
        source.RUN_ID, source.CHECK_NAME, source.STATUS,
        source.FAILURE_COUNT, source.ERROR_DETAILS, CURRENT_TIMESTAMP()
    );

    SELECT COALESCE(COUNT_IF(STATUS = 'FAILED'), 0)
      INTO :v_failed_check_count
      FROM SKYPOINTS_DB.CORE.COUNTRY_RECONCILIATION_CHECKS;

    v_overall_status := IFF(v_failed_check_count = 0, 'PASSED', 'FAILED');

    RETURN OBJECT_CONSTRUCT(
        'run_id', v_run_id,
        'status', v_overall_status,
        'failed_check_count', v_failed_check_count,
        'checked_at', v_started_at
    );
EXCEPTION
    WHEN OTHER THEN
        MERGE INTO SKYPOINTS_DB.AUDIT.COUNTRY_RECONCILIATION_AUDIT AS target
        USING
        (
            SELECT
                :v_run_id AS RUN_ID,
                'RECONCILIATION_EXECUTION' AS CHECK_NAME,
                'FAILED' AS STATUS,
                1::NUMBER(38, 0) AS FAILURE_COUNT,
                :SQLERRM AS ERROR_DETAILS
        ) AS source
           ON target.RUN_ID = source.RUN_ID
          AND target.CHECK_NAME = source.CHECK_NAME
        WHEN MATCHED THEN UPDATE SET
            STATUS = source.STATUS,
            FAILURE_COUNT = source.FAILURE_COUNT,
            ERROR_DETAILS = source.ERROR_DETAILS,
            EXECUTED_AT = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT
        (
            RUN_ID, CHECK_NAME, STATUS, FAILURE_COUNT, ERROR_DETAILS, EXECUTED_AT
        )
        VALUES
        (
            source.RUN_ID, source.CHECK_NAME, source.STATUS,
            source.FAILURE_COUNT, source.ERROR_DETAILS, CURRENT_TIMESTAMP()
        );
        RAISE;
END;
$$;

CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_RECONCILIATION
    WAREHOUSE = 'SKYPOINTS_ETL_WH'
    COMMENT = 'Validate country routing results and persist reconciliation checks'
    AFTER SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING
AS
    CALL SKYPOINTS_DB.AUDIT.SP_VALIDATE_COUNTRY_ROUTING();

ALTER TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_RECONCILIATION SUSPEND;
