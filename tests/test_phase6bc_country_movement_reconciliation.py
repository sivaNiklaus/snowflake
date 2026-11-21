"""Static Phase 6B-6C contract checks; these tests do not connect to Snowflake."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
ROUTING = (
    ROOT / "sql" / "processing" / "deploy_country_routing.sql"
).read_text(encoding="utf-8")
RECONCILIATION = (
    ROOT / "sql" / "processing" / "deploy_country_movement_reconciliation.sql"
).read_text(encoding="utf-8")
EXECUTION = (
    ROOT / "sql" / "orchestration" / "execute_country_routing.sql"
).read_text(encoding="utf-8")
PIPELINE_DEPLOYMENT = (
    ROOT / "sql" / "orchestration" / "deploy_unified_pipeline.sql"
).read_text(encoding="utf-8")
MONITORING = (
    ROOT / "sql" / "orchestration" / "monitor_country_routing.sql"
).read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")
SQL_README = (ROOT / "sql" / "README.md").read_text(encoding="utf-8")
APPROVED_COUNTRIES = [
    "USA", "IND", "GBR", "CAN", "AUS",
    "DEU", "FRA", "JPN", "SGP", "NZL",
    "ZAF", "BRA", "MEX", "ARE", "SAU",
    "KOR", "ITA", "ESP", "NLD", "CHE",
]


def test_reconciliation_uses_the_existing_twenty_country_allowlist() -> None:
    cursor = RECONCILIATION.split(
        "c_approved_country_tables CURSOR FOR", 1
    )[1].split(";", 1)[0]
    assert re.findall(r"\('([A-Z]{3})'\)", cursor) == APPROVED_COUNTRIES


def test_member_current_drives_multiple_country_movements() -> None:
    assert "FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT AS source" in ROUTING
    assert "OPEN c_active_route_countries;" in ROUTING
    assert "WHILE (v_country_code IS NOT NULL) DO" in ROUTING
    assert "WHERE UPPER(TRIM(COUNTRY)) = :v_country_code" in ROUTING
    assert "SELECT *\n            FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT" in ROUTING
    assert "LIMIT" not in ROUTING
    assert "WHEN NOT MATCHED THEN INSERT" in ROUTING
    assert "'MOVED'" in ROUTING


def test_movement_is_merge_before_cleanup_inside_one_transaction() -> None:
    transaction_start = ROUTING.index("BEGIN TRANSACTION;")
    member_merge = ROUTING.index("MERGE INTO IDENTIFIER(:v_target_fqn)")
    stale_delete = ROUTING.index("DELETE FROM IDENTIFIER(:v_target_fqn)")
    commit = ROUTING.index("COMMIT;", stale_delete)
    assert transaction_start < member_merge < stale_delete < commit
    assert "IF (v_transaction_started) THEN\n            ROLLBACK;" in ROUTING
    assert "STATUS = 'FAILED'" in ROUTING


def test_movement_and_reconciliation_audits_are_retry_idempotent() -> None:
    assert "ON target.RUN_ID = source.RUN_ID" in ROUTING
    assert "AND target.MEMBER_ID = source.MEMBER_ID" in ROUTING
    assert "ON target.RUN_ID = source.RUN_ID" in RECONCILIATION
    assert "AND target.CHECK_NAME = source.CHECK_NAME" in RECONCILIATION
    assert "ON target.MEMBER_ID = source.MEMBER_ID" in ROUTING


def test_movement_audit_captures_lineage_and_failure_outcomes() -> None:
    assert "CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.COUNTRY_MOVEMENT_AUDIT" in ROUTING
    for column in (
        "RUN_ID",
        "MEMBER_ID",
        "PREVIOUS_COUNTRY",
        "DESTINATION_COUNTRY",
        "ACTION",
        "STATUS",
        "ERROR_DETAILS",
    ):
        assert column in ROUTING
    assert "COUNTRY_ROUTING_PRIOR_MEMBERS" in ROUTING
    assert "LISTAGG(DISTINCT prior.COUNTRY_CODE" in ROUTING
    assert "MERGE INTO SKYPOINTS_DB.AUDIT.COUNTRY_MOVEMENT_AUDIT" in ROUTING
    assert "AND target.MEMBER_ID = source.MEMBER_ID" in ROUTING
    assert "SET STATUS = 'SUCCEEDED'" in ROUTING
    assert "SET STATUS = 'FAILED'" in ROUTING
    assert "'QUARANTINED', 'STARTED') AS STATUS" in ROUTING


def test_reconciliation_checks_all_required_routing_invariants() -> None:
    for check_name in (
        "MEMBER_CURRENT_UNIQUE_MEMBER_ID",
        "VALID_MEMBERS_EXACTLY_ONCE",
        "NO_DUPLICATE_COUNTRY_MEMBERS",
        "NO_WRONG_COUNTRY_ROWS",
        "NO_INVALID_DESTINATIONS_ROUTED",
        "ONLY_APPROVED_COUNTRY_TABLES",
        "COUNTRY_ROUTING_CONFIGURATION_VALID",
        "COUNTRY_TABLE_SCHEMA_COMPATIBLE",
    ):
        assert check_name in RECONCILIATION
    assert "HAVING COUNT(routed.MEMBER_ID) <> 1" in RECONCILIATION
    assert "HAVING COUNT(*) > 1" in RECONCILIATION
    assert "NULLIF(UPPER(TRIM(member.COUNTRY)), '') AS COUNTRY_CODE" in RECONCILIATION
    assert "HAS_VALID_DESTINATION" in RECONCILIATION
    assert "STARTSWITH(tables.TABLE_NAME, 'MEMBER_')" in RECONCILIATION
    assert "TARGET_TABLE IS DISTINCT FROM ('MEMBER_' || COUNTRY_CODE)" in RECONCILIATION
    assert "IS_ACTIVE IS NULL" in RECONCILIATION
    assert "NUMERIC_PRECISION IS DISTINCT FROM expected_columns.NUMERIC_PRECISION" in RECONCILIATION


def test_member_current_unique_member_id_fails_for_null_ids() -> None:
    null_id_check = RECONCILIATION.split(
        "INTO :v_null_member_id_count", 1
    )[1].split(";", 1)[0]
    assert "FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT" in null_id_check
    assert "WHERE MEMBER_ID IS NULL" in null_id_check
    assert "'MEMBER_CURRENT_UNIQUE_MEMBER_ID'" in RECONCILIATION
    assert "'null_member_id_rows=' || :v_null_member_id_count" in RECONCILIATION


def test_member_current_unique_member_id_fails_for_duplicate_ids() -> None:
    duplicate_id_check = RECONCILIATION.split(
        "INTO :v_duplicate_member_id_count", 1
    )[1].split(";", 1)[0]
    assert "FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT" in duplicate_id_check
    assert "WHERE MEMBER_ID IS NOT NULL" in duplicate_id_check
    assert "GROUP BY MEMBER_ID" in duplicate_id_check
    assert "HAVING COUNT(*) > 1" in duplicate_id_check
    assert "', duplicated_member_id_groups='" in RECONCILIATION
    assert "|| :v_duplicate_member_id_count" in RECONCILIATION


def test_valid_member_in_correct_country_passes_and_missing_member_fails() -> None:
    assert "WHERE HAS_VALID_DESTINATION" in RECONCILIATION
    assert "routed.COUNTRY_CODE = current_member.COUNTRY_CODE" in RECONCILIATION
    assert "HAVING COUNT(routed.MEMBER_ID) <> 1" in RECONCILIATION
    assert "COALESCE(COUNT_IF(" in RECONCILIATION
    assert "), 0) <> 1" in RECONCILIATION


def test_valid_member_in_wrong_country_fails() -> None:
    wrong_country = RECONCILIATION.split(
        "INTO :v_wrong_country_count", 1
    )[1].split(";", 1)[0]
    assert "member.HAS_VALID_DESTINATION" in wrong_country
    assert "routed.COUNTRY_CODE IS DISTINCT FROM member.COUNTRY_CODE" in wrong_country


def test_invalid_destination_preserves_only_audited_previous_country_rows() -> None:
    assert "movement.ACTION = 'QUARANTINED'" in RECONCILIATION
    assert "movement.STATUS = 'QUARANTINED'" in RECONCILIATION
    assert "invalid.COUNTRY_CODE IS NOT DISTINCT FROM movement.DESTINATION_COUNTRY" in RECONCILIATION
    assert "LATERAL SPLIT_TO_TABLE(movement.PREVIOUS_COUNTRY, ',')" in RECONCILIATION
    wrong_country = RECONCILIATION.split(
        "INTO :v_wrong_country_count", 1
    )[1].split(";", 1)[0]
    assert "NOT member.HAS_VALID_DESTINATION" in wrong_country
    assert "preserved.PREVIOUS_COUNTRY = routed.COUNTRY_CODE" in wrong_country
    invalid_route = RECONCILIATION.split(
        "INTO :v_invalid_destination_route_count", 1
    )[1].split(";", 1)[0]
    assert "NOT member.HAS_VALID_DESTINATION" in invalid_route
    assert "NOT EXISTS" in invalid_route
    assert "preserved.PREVIOUS_COUNTRY = routed.COUNTRY_CODE" in invalid_route


def test_invalid_destination_wrong_or_duplicate_routes_still_fail() -> None:
    assert "GROUP BY MEMBER_ID\n          HAVING COUNT(*) > 1" in RECONCILIATION
    assert "NO_DUPLICATE_COUNTRY_MEMBERS" in RECONCILIATION
    assert "NO_INVALID_DESTINATIONS_ROUTED" in RECONCILIATION
    assert "NOT EXISTS" in RECONCILIATION
    assert "ONLY_APPROVED_COUNTRY_TABLES" in RECONCILIATION


def test_reconciliation_is_persistent_idempotent_and_does_not_repair_data() -> None:
    assert "CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.COUNTRY_RECONCILIATION_AUDIT" in RECONCILIATION
    assert "PRIMARY KEY (RUN_ID, CHECK_NAME)" in RECONCILIATION
    assert "MERGE INTO SKYPOINTS_DB.AUDIT.COUNTRY_RECONCILIATION_AUDIT" in RECONCILIATION
    assert "'failed_check_count', v_failed_check_count" in RECONCILIATION
    assert "'status', v_overall_status" in RECONCILIATION
    procedure = RECONCILIATION.split(
        "CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.AUDIT.SP_VALIDATE_COUNTRY_ROUTING()",
        1,
    )[1].split(
        "CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_RECONCILIATION",
        1,
    )[0]
    assert "MERGE INTO SKYPOINTS_DB.CORE" not in procedure
    assert "UPDATE SKYPOINTS_DB.CORE.MEMBER_CURRENT" not in procedure
    assert "DELETE FROM IDENTIFIER" not in procedure


def test_reconciliation_task_is_downstream_suspended_and_manually_executed() -> None:
    task = RECONCILIATION.split(
        "CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_RECONCILIATION",
        1,
    )[1]
    assert "AFTER SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING" in task
    assert "WAREHOUSE = 'SKYPOINTS_ETL_WH'" in task
    assert "CALL SKYPOINTS_DB.AUDIT.SP_VALIDATE_COUNTRY_ROUTING()" in task
    assert "SCHEDULE =" not in RECONCILIATION.upper()
    assert "TASK_COUNTRY_RECONCILIATION SUSPEND" in RECONCILIATION
    assert PIPELINE_DEPLOYMENT.index(
        "TASK_COUNTRY_RECONCILIATION RESUME"
    ) < PIPELINE_DEPLOYMENT.index(
        "TASK_COUNTRY_ROUTING RESUME"
    )
    assert PIPELINE_DEPLOYMENT.index(
        "TASK_COUNTRY_RECONCILIATION SUSPEND"
    ) < PIPELINE_DEPLOYMENT.index(
        "TASK_COUNTRY_ROUTING SUSPEND"
    )
    assert "CALL SKYPOINTS_DB.AUDIT.SP_RUN_COMPLETE_PIPELINE()" in EXECUTION


def test_monitoring_and_documentation_cover_phase6b_and_phase6c() -> None:
    assert "TASK_COUNTRY_RECONCILIATION" in MONITORING
    assert "COUNTRY_MOVEMENT_AUDIT" in MONITORING
    assert "COUNTRY_RECONCILIATION_AUDIT" in MONITORING
    assert "OVERALL_STATUS" in MONITORING
    assert "Phase 6B" in README
    assert "Phase 6C" in README
    assert "SP_VALIDATE_COUNTRY_ROUTING" in README
    assert "Phase 6B" in SQL_README
    assert "Phase 6C" in SQL_README


def test_generated_reconciliation_preserves_only_latest_quarantined_country() -> None:
    generator = MONITORING.split(
        "-- Generate an exact reconciliation query", 1
    )[1]
    assert "COUNTRY_MOVEMENT_AUDIT AS movement" in generator
    assert "movement.ACTION = ''QUARANTINED''" in generator
    assert "movement.STATUS = ''QUARANTINED''" in generator
    assert "invalid.COUNTRY_CODE IS NOT DISTINCT FROM movement.DESTINATION_COUNTRY" in generator
    assert "PARTITION BY movement.MEMBER_ID" in generator
    assert "ORDER BY movement.UPDATED_AT DESC" in generator
    assert "SPLIT_TO_TABLE(movement.PREVIOUS_COUNTRY" in generator
    assert "preserved.PREVIOUS_COUNTRY = routed.COUNTRY_CODE" in generator
    assert "NOT status.HAS_VALID_DESTINATION AND NOT EXISTS" in generator


def test_generated_reconciliation_checks_current_member_id_uniqueness() -> None:
    generator = MONITORING.split(
        "-- Generate an exact reconciliation query", 1
    )[1]
    assert "WHERE MEMBER_ID IS NULL) AS MEMBER_CURRENT_NULL_MEMBER_IDS" in generator
    assert "GROUP BY MEMBER_ID HAVING COUNT(*) > 1" in generator
    assert "AS MEMBER_CURRENT_DUPLICATE_MEMBER_IDS" in generator


def test_generated_reconciliation_keeps_allowlist_and_is_read_only() -> None:
    generator = MONITORING.split(
        "-- Generate an exact reconciliation query", 1
    )[1]
    approved_values = generator.split("FROM VALUES", 1)[1].split(
        "AS approved(COUNTRY_CODE)", 1
    )[0]
    assert re.findall(r"\('([A-Z]{3})'\)", approved_values) == APPROVED_COUNTRIES
    assert not re.search(
        r"\b(?:INSERT\s+INTO|UPDATE\s+SKYPOINTS_DB|DELETE\s+FROM|MERGE\s+INTO|CALL\s+SKYPOINTS_DB)\b",
        generator,
        re.IGNORECASE,
    )
    assert "AS UNAPPROVED_COUNTRY_TABLES" in generator
