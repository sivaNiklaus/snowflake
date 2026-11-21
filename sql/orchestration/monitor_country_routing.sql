-- Recent execution history for the complete Phase 3-6C task graph.
SELECT
    NAME,
    STATE,
    GRAPH_RUN_GROUP_ID,
    SCHEDULED_TIME,
    QUERY_START_TIME,
    COMPLETED_TIME,
    ERROR_MESSAGE
FROM TABLE(SKYPOINTS_DB.INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP()),
    SCHEDULED_TIME_RANGE_END => CURRENT_TIMESTAMP(),
    DATABASE_NAME => 'SKYPOINTS_DB',
    SCHEMA_NAME => 'RAW',
    RESULT_LIMIT => 1000
))
WHERE NAME IN
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
)
ORDER BY SCHEDULED_TIME DESC;

-- Country configuration and physical row-count metadata for created tables.
SELECT
    config.COUNTRY_CODE,
    config.TARGET_TABLE,
    config.IS_ACTIVE,
    COALESCE(tables.ROW_COUNT, 0) AS TABLE_ROW_COUNT,
    tables.LAST_ALTERED
FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG AS config
LEFT JOIN SKYPOINTS_DB.INFORMATION_SCHEMA.TABLES AS tables
  ON tables.TABLE_SCHEMA = 'CORE'
 AND tables.TABLE_NAME = config.TARGET_TABLE
 AND tables.TABLE_TYPE = 'BASE TABLE'
ORDER BY config.COUNTRY_CODE;

-- Country routing run outcomes and operation counts.
SELECT
    RUN_ID,
    STARTED_AT,
    ENDED_AT,
    STATUS,
    TOTAL_MEMBERS,
    ROUTED_MEMBERS,
    INSERTED_COUNT,
    UPDATED_COUNT,
    REMOVED_COUNT,
    QUARANTINED_COUNT,
    ERROR_DETAILS
FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_AUDIT
ORDER BY STARTED_AT DESC
LIMIT 100;

-- Per-member country movement and synchronization outcomes.
SELECT
    RUN_ID,
    MEMBER_ID,
    PREVIOUS_COUNTRY,
    DESTINATION_COUNTRY,
    ACTION,
    STATUS,
    ERROR_DETAILS,
    CREATED_AT,
    UPDATED_AT
FROM SKYPOINTS_DB.AUDIT.COUNTRY_MOVEMENT_AUDIT
ORDER BY UPDATED_AT DESC
LIMIT 500;

-- Persistent checks and run-level reconciliation summary.
SELECT
    RUN_ID,
    CHECK_NAME,
    STATUS,
    FAILURE_COUNT,
    ERROR_DETAILS,
    EXECUTED_AT
FROM SKYPOINTS_DB.AUDIT.COUNTRY_RECONCILIATION_AUDIT
ORDER BY EXECUTED_AT DESC, CHECK_NAME
LIMIT 500;

SELECT
    RUN_ID,
    IFF(COUNT_IF(STATUS = 'FAILED') > 0, 'FAILED', 'PASSED') AS OVERALL_STATUS,
    COUNT(*) AS CHECK_COUNT,
    COALESCE(SUM(FAILURE_COUNT), 0) AS TOTAL_FAILURE_COUNT,
    MAX(EXECUTED_AT) AS COMPLETED_AT
FROM SKYPOINTS_DB.AUDIT.COUNTRY_RECONCILIATION_AUDIT
GROUP BY RUN_ID
ORDER BY COMPLETED_AT DESC
LIMIT 100;

-- Routing failure reasons retained in the existing DQ quarantine table.
SELECT
    failures.VALUE:message::VARCHAR AS FAILURE_REASON,
    COUNT(*) AS QUARANTINED_RECORDS,
    MIN(quarantine.QUARANTINED_AT) AS FIRST_QUARANTINED_AT,
    MAX(quarantine.QUARANTINED_AT) AS LAST_QUARANTINED_AT
FROM SKYPOINTS_DB.STAGING.DQ_QUARANTINE AS quarantine,
     LATERAL FLATTEN(INPUT => quarantine.FAILURE_REASONS) AS failures
WHERE quarantine.DATASET_NAME = 'MEMBER_ROUTING'
  AND failures.VALUE:message::VARCHAR IN
      ('UNSUPPORTED_COUNTRY', 'INACTIVE_COUNTRY', 'MISSING_COUNTRY')
GROUP BY failures.VALUE:message::VARCHAR
ORDER BY FAILURE_REASON;

-- Generate an exact reconciliation query for currently existing, approved
-- country tables. Copy and run the returned SQL text in the same account.
WITH approved_tables AS
(
    SELECT approved.COUNTRY_CODE, 'MEMBER_' || approved.COUNTRY_CODE AS TARGET_TABLE
    FROM VALUES
        ('USA'), ('IND'), ('GBR'), ('CAN'), ('AUS'),
        ('DEU'), ('FRA'), ('JPN'), ('SGP'), ('NZL'),
        ('ZAF'), ('BRA'), ('MEX'), ('ARE'), ('SAU'),
        ('KOR'), ('ITA'), ('ESP'), ('NLD'), ('CHE')
        AS approved(COUNTRY_CODE)
    JOIN SKYPOINTS_DB.INFORMATION_SCHEMA.TABLES AS tables
      ON tables.TABLE_SCHEMA = 'CORE'
     AND tables.TABLE_NAME = 'MEMBER_' || approved.COUNTRY_CODE
     AND tables.TABLE_TYPE = 'BASE TABLE'
)
SELECT
    'WITH routed AS ('
    || COALESCE(
        LISTAGG(
            'SELECT ''' || COUNTRY_CODE
            || '''::VARCHAR(3) AS COUNTRY_CODE, MEMBER_ID '
            || 'FROM SKYPOINTS_DB.CORE.' || TARGET_TABLE,
            ' UNION ALL '
        ) WITHIN GROUP (ORDER BY COUNTRY_CODE),
        'SELECT NULL::VARCHAR(3) AS COUNTRY_CODE, '
        || 'NULL::VARCHAR AS MEMBER_ID WHERE FALSE'
    )
    || '), member_status AS ('
    || 'SELECT member.MEMBER_ID, NULLIF(UPPER(TRIM(member.COUNTRY)), '''') AS COUNTRY_CODE, '
    || 'EXISTS (SELECT 1 FROM SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG AS config '
    || 'WHERE config.COUNTRY_CODE = UPPER(TRIM(member.COUNTRY)) AND config.IS_ACTIVE '
    || 'AND config.COUNTRY_CODE IN '
    || '(''USA'',''IND'',''GBR'',''CAN'',''AUS'',''DEU'',''FRA'',''JPN'','
    || '''SGP'',''NZL'',''ZAF'',''BRA'',''MEX'',''ARE'',''SAU'',''KOR'','
    || '''ITA'',''ESP'',''NLD'',''CHE'')) AS HAS_VALID_DESTINATION '
    || 'FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT AS member'
    || '), invalid_destinations AS ('
    || 'SELECT MEMBER_ID, COUNTRY_CODE FROM member_status WHERE NOT HAS_VALID_DESTINATION'
    || '), latest_quarantined_movements AS ('
    || 'SELECT movement.MEMBER_ID, movement.PREVIOUS_COUNTRY '
    || 'FROM SKYPOINTS_DB.AUDIT.COUNTRY_MOVEMENT_AUDIT AS movement '
    || 'JOIN invalid_destinations AS invalid ON invalid.MEMBER_ID = movement.MEMBER_ID '
    || 'AND invalid.COUNTRY_CODE IS NOT DISTINCT FROM movement.DESTINATION_COUNTRY '
    || 'WHERE movement.ACTION = ''QUARANTINED'' AND movement.STATUS = ''QUARANTINED'' '
    || 'QUALIFY ROW_NUMBER() OVER (PARTITION BY movement.MEMBER_ID '
    || 'ORDER BY movement.UPDATED_AT DESC) = 1'
    || '), preserved AS ('
    || 'SELECT DISTINCT movement.MEMBER_ID, '
    || 'UPPER(TRIM(previous_country.VALUE::VARCHAR)) AS PREVIOUS_COUNTRY '
    || 'FROM latest_quarantined_movements AS movement, '
    || 'LATERAL SPLIT_TO_TABLE(movement.PREVIOUS_COUNTRY, '','') AS previous_country '
    || 'WHERE previous_country.VALUE IS NOT NULL'
    || ') SELECT '
    || '(SELECT COALESCE(COUNT_IF(route_count <> 1 OR matching_count <> 1), 0) '
    || 'FROM (SELECT current_member.MEMBER_ID, current_member.COUNTRY_CODE, '
    || 'COUNT(routed.MEMBER_ID) AS route_count, '
    || 'COALESCE(COUNT_IF(routed.COUNTRY_CODE = current_member.COUNTRY_CODE), 0) AS matching_count '
    || 'FROM member_status AS current_member LEFT JOIN routed '
    || 'ON routed.MEMBER_ID = current_member.MEMBER_ID '
    || 'WHERE current_member.HAS_VALID_DESTINATION '
    || 'GROUP BY current_member.MEMBER_ID, current_member.COUNTRY_CODE) '
    || 'AS member_route_counts) '
    || 'AS VALID_CURRENT_NOT_ROUTED_EXACTLY_ONCE, '
    || '(SELECT COUNT(*) FROM (SELECT MEMBER_ID FROM routed '
    || 'GROUP BY MEMBER_ID HAVING COUNT(*) > 1) AS duplicated_routes) '
    || 'AS MEMBER_IDS_DUPLICATED_ACROSS_COUNTRY_TABLES, '
    || '(SELECT COUNT(*) FROM routed '
    || 'LEFT JOIN member_status AS status ON status.MEMBER_ID = routed.MEMBER_ID '
    || 'WHERE status.MEMBER_ID IS NULL '
    || 'OR (status.HAS_VALID_DESTINATION AND routed.COUNTRY_CODE '
    || 'IS DISTINCT FROM status.COUNTRY_CODE) '
    || 'OR (NOT status.HAS_VALID_DESTINATION AND NOT EXISTS '
    || '(SELECT 1 FROM preserved WHERE preserved.MEMBER_ID = routed.MEMBER_ID '
    || 'AND preserved.PREVIOUS_COUNTRY = routed.COUNTRY_CODE))) '
    || 'AS MEMBERS_IN_WRONG_COUNTRY_TABLE, '
    || '(SELECT COUNT(*) FROM routed '
    || 'JOIN member_status AS status ON status.MEMBER_ID = routed.MEMBER_ID '
    || 'WHERE NOT status.HAS_VALID_DESTINATION AND NOT EXISTS '
    || '(SELECT 1 FROM preserved WHERE preserved.MEMBER_ID = routed.MEMBER_ID '
    || 'AND preserved.PREVIOUS_COUNTRY = routed.COUNTRY_CODE)) '
    || 'AS UNSUPPORTED_INACTIVE_OR_MISSING_MEMBERS_ROUTED, '
    || '(SELECT COUNT(*) FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT '
    || 'WHERE MEMBER_ID IS NULL) AS MEMBER_CURRENT_NULL_MEMBER_IDS, '
    || '(SELECT COUNT(*) FROM (SELECT MEMBER_ID '
    || 'FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT WHERE MEMBER_ID IS NOT NULL '
    || 'GROUP BY MEMBER_ID HAVING COUNT(*) > 1) AS duplicate_current_ids) '
    || 'AS MEMBER_CURRENT_DUPLICATE_MEMBER_IDS, '
    || '(SELECT COUNT(*) FROM SKYPOINTS_DB.INFORMATION_SCHEMA.TABLES '
    || 'WHERE TABLE_SCHEMA = ''CORE'' AND TABLE_TYPE = ''BASE TABLE'' '
    || 'AND STARTSWITH(TABLE_NAME, ''MEMBER_'') '
    || 'AND TABLE_NAME NOT IN (''MEMBER_CURRENT'', ''MEMBER_HISTORY'', '
    || '''MEMBER_USA'', ''MEMBER_IND'', ''MEMBER_GBR'', ''MEMBER_CAN'', '
    || '''MEMBER_AUS'', ''MEMBER_DEU'', ''MEMBER_FRA'', ''MEMBER_JPN'', '
    || '''MEMBER_SGP'', ''MEMBER_NZL'', ''MEMBER_ZAF'', ''MEMBER_BRA'', '
    || '''MEMBER_MEX'', ''MEMBER_ARE'', ''MEMBER_SAU'', ''MEMBER_KOR'', '
    || '''MEMBER_ITA'', ''MEMBER_ESP'', ''MEMBER_NLD'', ''MEMBER_CHE'')) '
    || 'AS UNAPPROVED_COUNTRY_TABLES;'
    AS RECONCILIATION_SQL
FROM approved_tables;
