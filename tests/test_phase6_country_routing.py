"""Static Phase 6A contract checks; these tests do not connect to Snowflake."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
ROUTING_DEPLOYMENT = (
    ROOT / "sql" / "processing" / "deploy_country_routing.sql"
).read_text(encoding="utf-8")
ROUTING_EXECUTION = (
    ROOT / "sql" / "orchestration" / "execute_country_routing.sql"
).read_text(encoding="utf-8")
ROUTING_MONITORING = (
    ROOT / "sql" / "orchestration" / "monitor_country_routing.sql"
).read_text(encoding="utf-8")
PHASE45_DEPLOYMENT = (
    ROOT / "sql" / "processing" / "deploy_ingestion_dq_and_business_transformation.sql"
).read_text(encoding="utf-8")

APPROVED_COUNTRIES = [
    "USA", "IND", "GBR", "CAN", "AUS",
    "DEU", "FRA", "JPN", "SGP", "NZL",
    "ZAF", "BRA", "MEX", "ARE", "SAU",
    "KOR", "ITA", "ESP", "NLD", "CHE",
]


def test_exactly_twenty_approved_country_codes_are_seeded_idempotently() -> None:
    seed = ROUTING_DEPLOYMENT.split(
        "MERGE INTO SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG", 1
    )[1].split(";", 1)[0]
    seeded = re.findall(r"\('([A-Z]{3})'\)", seed)
    assert seeded == APPROVED_COUNTRIES
    assert "WHEN MATCHED THEN UPDATE" not in seed
    assert "TARGET_TABLE = source.TARGET_TABLE" not in seed
    assert "IS_ACTIVE = source" not in seed
    assert "WHEN NOT MATCHED THEN INSERT" in seed
    assert "IS_ACTIVE, CREATED_AT, UPDATED_AT" in seed
    assert "TRUE," in seed


def test_duplicate_country_configuration_is_detected_before_routing() -> None:
    assert "HAVING COUNT(*) > 1" in ROUTING_DEPLOYMENT
    assert "v_duplicate_config_count > 0" in ROUTING_DEPLOYMENT
    assert "duplicate_country_codes=" in ROUTING_DEPLOYMENT


def test_invalid_target_names_fail_before_identifier_usage_and_are_audited() -> None:
    assert "v_missing_config_count > 0" in ROUTING_DEPLOYMENT
    assert "v_unapproved_config_count > 0" in ROUTING_DEPLOYMENT
    assert "v_invalid_target_count > 0" in ROUTING_DEPLOYMENT
    assert "v_null_active_count > 0" in ROUTING_DEPLOYMENT
    assert "TARGET_TABLE IS DISTINCT FROM ('MEMBER_' || COUNTRY_CODE)" in ROUTING_DEPLOYMENT
    assert "RAISE e_invalid_country_config;" in ROUTING_DEPLOYMENT
    assert (
        "Country routing configuration validation failed: duplicate_country_codes="
        in ROUTING_DEPLOYMENT
    )
    assert "ERROR_DETAILS = COALESCE(:v_config_error, :SQLERRM)" in ROUTING_DEPLOYMENT
    validation_position = ROUTING_DEPLOYMENT.index("v_duplicate_config_count > 0")
    identifier_position = ROUTING_DEPLOYMENT.index(
        "CREATE TABLE IF NOT EXISTS IDENTIFIER(:v_target_fqn)"
    )
    assert validation_position < identifier_position


def test_country_decisions_reject_missing_unsupported_and_inactive_codes() -> None:
    assert "THEN 'MISSING_COUNTRY'" in ROUTING_DEPLOYMENT
    assert "THEN 'UNSUPPORTED_COUNTRY'" in ROUTING_DEPLOYMENT
    assert "THEN 'INACTIVE_COUNTRY'" in ROUTING_DEPLOYMENT
    assert "WHEN NOT config.IS_ACTIVE" in ROUTING_DEPLOYMENT
    assert "'UNSUPPORTED_COUNTRY', 'INACTIVE_COUNTRY', 'MISSING_COUNTRY'" in ROUTING_MONITORING
    assert "config.COUNTRY_CODE IN" in ROUTING_DEPLOYMENT


def test_country_tables_are_created_lazily_from_member_current_schema() -> None:
    assert "CREATE TABLE IF NOT EXISTS IDENTIFIER(:v_target_fqn)" in ROUTING_DEPLOYMENT
    assert "LIKE SKYPOINTS_DB.CORE.MEMBER_CURRENT" in ROUTING_DEPLOYMENT
    assert "decisions.FAILURE_REASON IS NULL" in ROUTING_DEPLOYMENT
    assert "WHERE config.IS_ACTIVE" in ROUTING_DEPLOYMENT
    assert "config.TARGET_TABLE = 'MEMBER_' || config.COUNTRY_CODE" in ROUTING_DEPLOYMENT
    assert "IDENTIFIER(:v_target_fqn)" in ROUTING_DEPLOYMENT
    assert "EXECUTE IMMEDIATE" not in ROUTING_DEPLOYMENT.upper()
    assert not re.search(
        r"CREATE TABLE IF NOT EXISTS SKYPOINTS_DB\.CORE\.MEMBER_[A-Z]{3}",
        ROUTING_DEPLOYMENT,
    )


def test_routing_iterates_cursors_without_record_field_dereferences() -> None:
    assert "c_active_route_countries CURSOR FOR" in ROUTING_DEPLOYMENT
    assert "c_configured_countries CURSOR FOR" in ROUTING_DEPLOYMENT
    assert ROUTING_DEPLOYMENT.count(
        "FETCH c_active_route_countries INTO v_country_code, v_target_table"
    ) == 4
    assert ROUTING_DEPLOYMENT.count(
        "FETCH c_configured_countries INTO v_country_code, v_target_table"
    ) == 4
    assert ROUTING_DEPLOYMENT.count("WHILE (v_country_code IS NOT NULL) DO") == 4
    assert "route_country.COUNTRY_CODE" not in ROUTING_DEPLOYMENT
    assert "configured_country.COUNTRY_CODE" not in ROUTING_DEPLOYMENT


def test_country_merge_columns_match_existing_member_current_definition() -> None:
    current_table = re.search(
        r"CREATE TABLE IF NOT EXISTS SKYPOINTS_DB\.CORE\.MEMBER_CURRENT\s*"
        r"\((.*?)\)\s*COMMENT",
        PHASE45_DEPLOYMENT,
        flags=re.DOTALL,
    )
    country_merge = ROUTING_DEPLOYMENT.split(
        "MERGE INTO IDENTIFIER(:v_target_fqn)", 1
    )[1]
    route_insert = re.search(
        r"WHEN NOT MATCHED THEN INSERT\s*\((.*?)\)\s*VALUES\s*\(",
        country_merge,
        flags=re.DOTALL,
    )
    assert current_table is not None
    assert route_insert is not None
    current_columns = [
        line.strip().split()[0].rstrip(",")
        for line in current_table.group(1).splitlines()
        if line.strip() and not line.strip().upper().startswith("PRIMARY KEY")
    ]
    routed_columns = [
        column.strip()
        for column in route_insert.group(1).split(",")
    ]
    assert routed_columns == current_columns
    assert "LIKE SKYPOINTS_DB.CORE.MEMBER_CURRENT" in ROUTING_DEPLOYMENT


def test_routing_quarantines_once_with_existing_schema_and_original_member_data() -> None:
    assert "SKYPOINTS_DB.STAGING.DQ_QUARANTINE" in ROUTING_DEPLOYMENT
    assert "'MEMBER_ROUTING' AS DATASET_NAME" in ROUTING_DEPLOYMENT
    assert "ORIGINAL_RECORD, ORIGINAL_PAYLOAD" in ROUTING_DEPLOYMENT
    assert "SOURCE_RECORD AS ORIGINAL_RECORD" in ROUTING_DEPLOYMENT
    assert "ORIGINAL_MEMBER_DATA AS ORIGINAL_PAYLOAD" in ROUTING_DEPLOYMENT
    assert "FAILURE_REASONS" in ROUTING_DEPLOYMENT
    assert "SHA2(TO_JSON(ARRAY_CONSTRUCT(" in ROUTING_DEPLOYMENT
    assert "target.RECORD_KEY = source.RECORD_KEY" in ROUTING_DEPLOYMENT
    assert "ORIGINAL_PAYLOAD = source.ORIGINAL_PAYLOAD" in ROUTING_DEPLOYMENT
    assert "WHEN MATCHED THEN UPDATE SET\n        RUN_ID = source.RUN_ID" in ROUTING_DEPLOYMENT


def test_route_merges_before_transactional_removal_and_tracks_operation_counts() -> None:
    transaction_start = ROUTING_DEPLOYMENT.index("BEGIN TRANSACTION;")
    member_merge = ROUTING_DEPLOYMENT.index("MERGE INTO IDENTIFIER(:v_target_fqn)")
    stale_delete = ROUTING_DEPLOYMENT.index("DELETE FROM IDENTIFIER(:v_target_fqn)")
    commit = ROUTING_DEPLOYMENT.index("COMMIT;", stale_delete)
    assert transaction_start < member_merge < stale_delete < commit
    assert "COUNT_IF(target.MEMBER_ID IS NULL)" in ROUTING_DEPLOYMENT
    assert "v_inserted_count := v_inserted_count + v_country_inserts" in ROUTING_DEPLOYMENT
    assert "v_updated_count := v_updated_count + v_country_updates" in ROUTING_DEPLOYMENT
    assert "v_removed_count := v_removed_count + v_country_removals" in ROUTING_DEPLOYMENT
    assert "v_routed_members := 0;" in ROUTING_DEPLOYMENT
    assert "ERROR_DETAILS = COALESCE(:v_config_error, :SQLERRM)" in ROUTING_DEPLOYMENT
    assert "RAISE;" in ROUTING_DEPLOYMENT
    assert "MEMBER_HISTORY" not in ROUTING_DEPLOYMENT


def test_invalid_destination_quarantines_but_preserves_existing_country_rows() -> None:
    cleanup = ROUTING_DEPLOYMENT.split(
        "-- All valid destinations are merged before stale country rows are removed.",
        1,
    )[1]
    delete_statement = cleanup.split("DELETE FROM IDENTIFIER(:v_target_fqn)", 1)[1].split(
        ";", 1
    )[0]
    assert "FAILURE_REASON IS NULL" in delete_statement
    assert "FAILURE_REASON IS NOT NULL" not in delete_statement
    assert "NORMALIZED_COUNTRY IS DISTINCT FROM :v_country_code" in delete_statement
    assert "MEMBER_ID NOT IN" in delete_statement
    assert "FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT" in delete_statement
    assert "WHERE FAILURE_REASON IS NOT NULL" in ROUTING_DEPLOYMENT


def test_country_routing_task_follows_phase45_and_remains_manual() -> None:
    task = ROUTING_DEPLOYMENT.split(
        "CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING", 1
    )[1]
    assert "WAREHOUSE = 'SKYPOINTS_ETL_WH'" in task
    assert "AFTER SKYPOINTS_DB.RAW.TASK_REDEMPTION_PROCESSING" in task
    assert "CALL SKYPOINTS_DB.CORE.SP_ROUTE_MEMBERS_BY_COUNTRY()" in task
    assert "SCHEDULE =" not in ROUTING_DEPLOYMENT.upper()
    assert "TASK_COUNTRY_ROUTING SUSPEND" in ROUTING_DEPLOYMENT
    assert "CALL SKYPOINTS_DB.AUDIT.SP_RUN_COMPLETE_PIPELINE()" in ROUTING_EXECUTION
    assert "ALTER TASK" not in ROUTING_EXECUTION.upper()


def test_monitoring_includes_counts_quarantine_audit_and_reconciliation() -> None:
    assert "TASK_COUNTRY_ROUTING" in ROUTING_MONITORING
    assert "COUNTRY_ROUTING_CONFIG" in ROUTING_MONITORING
    assert "COUNTRY_ROUTING_AUDIT" in ROUTING_MONITORING
    assert "TABLE_ROW_COUNT" in ROUTING_MONITORING
    assert "DQ_QUARANTINE" in ROUTING_MONITORING
    assert "RECONCILIATION_SQL" in ROUTING_MONITORING
    assert "VALID_CURRENT_NOT_ROUTED_EXACTLY_ONCE" in ROUTING_MONITORING
    assert "MEMBER_IDS_DUPLICATED_ACROSS_COUNTRY_TABLES" in ROUTING_MONITORING
    assert "MEMBERS_IN_WRONG_COUNTRY_TABLE" in ROUTING_MONITORING
    assert "UNSUPPORTED_INACTIVE_OR_MISSING_MEMBERS_ROUTED" in ROUTING_MONITORING
    assert "AS member_route_counts" in ROUTING_MONITORING
    assert "AS duplicated_routes" in ROUTING_MONITORING
    assert "WHERE status.MEMBER_ID IS NULL" in ROUTING_MONITORING
    assert "routed.COUNTRY_CODE '" in ROUTING_MONITORING
    assert "'IS DISTINCT FROM status.COUNTRY_CODE)" in ROUTING_MONITORING
