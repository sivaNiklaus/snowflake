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
    assert "WHEN MATCHED THEN UPDATE SET\n    TARGET_TABLE = source.TARGET_TABLE" in seed
    assert "IS_ACTIVE = source" not in seed
    assert "WHEN NOT MATCHED THEN INSERT" in seed
    assert "IS_ACTIVE, CREATED_AT, UPDATED_AT" in seed
    assert "TRUE," in seed


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
    assert "ERROR_DETAILS = :SQLERRM" in ROUTING_DEPLOYMENT
    assert "RAISE;" in ROUTING_DEPLOYMENT
    assert "MEMBER_HISTORY" not in ROUTING_DEPLOYMENT


def test_country_routing_task_follows_phase45_and_remains_manual() -> None:
    task = ROUTING_DEPLOYMENT.split(
        "CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING", 1
    )[1]
    assert "WAREHOUSE = 'SKYPOINTS_ETL_WH'" in task
    assert "AFTER SKYPOINTS_DB.RAW.TASK_REDEMPTION_PROCESSING" in task
    assert "CALL SKYPOINTS_DB.CORE.SP_ROUTE_MEMBERS_BY_COUNTRY()" in task
    assert "SCHEDULE =" not in ROUTING_DEPLOYMENT.upper()
    assert "TASK_COUNTRY_ROUTING SUSPEND" in ROUTING_DEPLOYMENT
    assert ROUTING_EXECUTION.index("TASK_COUNTRY_ROUTING RESUME") < ROUTING_EXECUTION.index(
        "TASK_REDEMPTION_PROCESSING RESUME"
    )
    assert ROUTING_EXECUTION.index("TASK_REDEMPTION_INGESTION RESUME") < ROUTING_EXECUTION.index(
        "EXECUTE TASK"
    )
    assert "EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT" in ROUTING_EXECUTION
    assert ROUTING_EXECUTION.index("TASK_COUNTRY_ROUTING SUSPEND") > ROUTING_EXECUTION.index(
        "EXECUTE TASK"
    )


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
    assert "WHERE member.MEMBER_ID IS NULL OR routed.COUNTRY_CODE" in ROUTING_MONITORING
