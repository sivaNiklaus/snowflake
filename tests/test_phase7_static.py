"""Static Phase 7 contract checks; these tests do not connect to Snowflake."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
ORCHESTRATION = ROOT / "sql" / "02_orchestration_ingestion"
PROCESSING = ROOT / "sql" / "03_processing" / "dq_and_transformation"
COUNTRY_ROUTING = ROOT / "sql" / "03_processing" / "country_routing"
COUNTRY_RECONCILIATION = (
    ROOT / "sql" / "03_processing" / "country_movement_reconciliation"
)
UNIFIED_PIPELINE = ROOT / "sql" / "04_unified_pipeline"
TASK_DEPLOYMENT = (
    ORCHESTRATION / "deploy_ingestion_task_graph.sql"
).read_text(encoding="utf-8")
PHASE45 = (
    PROCESSING / "deploy_ingestion_dq_and_business_transformation.sql"
).read_text(encoding="utf-8")
ROUTING = (COUNTRY_ROUTING / "deploy_country_routing.sql").read_text(encoding="utf-8")
RECONCILIATION = (
    COUNTRY_RECONCILIATION / "deploy_country_movement_reconciliation.sql"
).read_text(encoding="utf-8")
PIPELINE_DEPLOYMENT = (
    UNIFIED_PIPELINE / "deploy_unified_pipeline.sql"
).read_text(encoding="utf-8")
PIPELINE_MONITORING = (
    UNIFIED_PIPELINE / "monitor_unified_pipeline.sql"
).read_text(encoding="utf-8")

TASKS = [
    "TASK_MEMBER_INGESTION",
    "TASK_REDEMPTION_INGESTION",
    "TASK_INGESTION_VALIDATION",
    "TASK_PARSE_AND_NORMALIZE",
    "TASK_DQ_VALIDATION",
    "TASK_MEMBER_PROCESSING",
    "TASK_REDEMPTION_PROCESSING",
    "TASK_COUNTRY_ROUTING",
    "TASK_COUNTRY_RECONCILIATION",
]


def test_complete_graph_order_and_existing_dependencies_are_preserved() -> None:
    declarations = (
        TASK_DEPLOYMENT + PHASE45 + ROUTING + RECONCILIATION
    )
    assert [name for name in TASKS if f"CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.{name}" in declarations] == TASKS
    for predecessor, successor in zip(TASKS[1:], TASKS[2:]):
        assert f"AFTER SKYPOINTS_DB.RAW.{predecessor}" in declarations
        assert f"CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.{successor}" in declarations
    assert "AFTER SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION" in TASK_DEPLOYMENT
    assert "AFTER SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION" in TASK_DEPLOYMENT
    assert "AFTER SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING" in RECONCILIATION
    assert "TASK_MEMBER_INGESTION SUSPEND" in PIPELINE_DEPLOYMENT
    assert "SCHEDULE =" not in PIPELINE_DEPLOYMENT.upper()


def test_unified_entry_point_resumes_descendants_and_cleans_up_on_both_paths() -> None:
    resume = re.findall(
        r"ALTER TASK SKYPOINTS_DB\.RAW\.(TASK_\w+) RESUME",
        PIPELINE_DEPLOYMENT,
    )
    assert resume == list(reversed(TASKS[1:]))
    assert "EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT" in PIPELINE_DEPLOYMENT
    assert PIPELINE_DEPLOYMENT.count(
        "CALL SKYPOINTS_DB.AUDIT.SP_SUSPEND_PIPELINE_DESCENDANTS()"
    ) >= 2
    assert "WHEN OTHER THEN" in PIPELINE_DEPLOYMENT
    assert "RAISE;" in PIPELINE_DEPLOYMENT
    suspend_helper = PIPELINE_DEPLOYMENT.split(
        "CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.AUDIT.SP_SUSPEND_PIPELINE_DESCENDANTS()",
        1,
    )[1].split(
        "CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.AUDIT.SP_RUN_COMPLETE_PIPELINE()",
        1,
    )[0]
    assert [
        name for name in reversed(TASKS)
        if f"{name} SUSPEND" in suspend_helper
    ] == list(reversed(TASKS))
    assert "ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION SUSPEND" in PIPELINE_DEPLOYMENT


def test_unified_runner_prevents_overlapping_graph_runs_and_reports_run_id() -> None:
    assert "PIPELINE_RUN_CONTROL" in PIPELINE_DEPLOYMENT
    assert "STATUS = 'IDLE'" in PIPELINE_DEPLOYMENT
    assert "v_lock_rows := SQLROWCOUNT" in PIPELINE_DEPLOYMENT
    assert "STATUS = 'BLOCKED'" in PIPELINE_DEPLOYMENT
    assert "'graph_run_id', v_graph_run_id" in PIPELINE_DEPLOYMENT
    assert "GRAPH_RUN_GROUP_ID" in PIPELINE_DEPLOYMENT
    assert "STATUS = 'SUCCEEDED'" in PIPELINE_DEPLOYMENT
    assert "TASK_COUNT = :v_task_count" in PIPELINE_DEPLOYMENT
    assert "v_success_count <> 9" in PIPELINE_DEPLOYMENT


def test_reconciliation_failure_is_a_failed_graph_and_is_audited() -> None:
    assert "EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT" in PIPELINE_DEPLOYMENT
    assert "v_error_details := COALESCE(v_error_details, SQLERRM)" in PIPELINE_DEPLOYMENT
    assert "v_failed_tasks" in PIPELINE_DEPLOYMENT
    assert "v_task_errors" in PIPELINE_DEPLOYMENT
    assert "COUNTRY_RECONCILIATION_AUDIT" in PIPELINE_DEPLOYMENT
    assert "CHECK_NAME = 'RECONCILIATION_EXECUTION'" in PIPELINE_DEPLOYMENT
    assert "v_error_details := v_task_errors" in PIPELINE_DEPLOYMENT
    assert "STATUS = 'FAILED'" in PIPELINE_DEPLOYMENT
    assert "FAILED_TASKS = :v_failed_tasks" in PIPELINE_DEPLOYMENT
    assert "ERROR_DETAILS = :v_error_details" in PIPELINE_DEPLOYMENT
    assert "v_success_count <> 9 OR v_failed_task_count > 0" in PIPELINE_DEPLOYMENT
    assert "RAISE;" in PIPELINE_DEPLOYMENT


def test_raw_copy_and_ingestion_audits_are_retry_idempotent() -> None:
    assert TASK_DEPLOYMENT.count("COPY INTO SKYPOINTS_DB.RAW.") == 2
    assert "FORCE = TRUE" not in TASK_DEPLOYMENT.upper()
    assert TASK_DEPLOYMENT.count(
        "MERGE INTO SKYPOINTS_DB.AUDIT.INGESTION_AUDIT AS target"
    ) == 3
    assert TASK_DEPLOYMENT.count("ON target.RUN_ID = source.RUN_ID") == 3
    assert "RESULT_SCAN(:v_copy_query_id)" in TASK_DEPLOYMENT
    assert "SOURCE_FILES" in TASK_DEPLOYMENT


def test_downstream_processing_uses_file_stage_watermarks_and_records_failures() -> None:
    assert "CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.AUDIT.ETL_FILE_STAGE_STATUS" in PHASE45
    for stage_name in (
        "PARSE",
        "DQ",
        "MEMBER_PROCESSING",
        "REDEMPTION_PROCESSING",
    ):
        assert f"'{stage_name}' AS STAGE_NAME" in PHASE45
        assert f"STAGE_NAME = '{stage_name}'" in PHASE45
    assert "checkpoint.STATUS = 'SUCCEEDED'" in PHASE45
    assert "STATUS = 'FAILED'" in PHASE45
    assert "PENDING_MEMBER_PARSE_FILES" in PHASE45
    assert "PENDING_REDEMPTION_PARSE_FILES" in PHASE45
    assert "PENDING_MEMBER_DQ_FILES" in PHASE45
    assert "PENDING_REDEMPTION_DQ_FILES" in PHASE45
    assert "PENDING_MEMBER_PROCESSING_FILES" in PHASE45
    assert "PENDING_REDEMPTION_PROCESSING_FILES" in PHASE45
    assert "checkpoint.STAGE_NAME = 'MEMBER_PROCESSING'" in PHASE45
    assert "checkpoint.STAGE_NAME = 'REDEMPTION_PROCESSING'" in PHASE45


def test_retries_reprocess_incomplete_files_with_idempotent_business_merges() -> None:
    assert "target.RECORD_KEY = source.RECORD_KEY" in PHASE45
    assert "MERGE INTO SKYPOINTS_DB.CORE.MEMBER_CURRENT AS target" in PHASE45
    assert "MERGE INTO SKYPOINTS_DB.CORE.REDEMPTION_FACT AS target" in PHASE45
    assert "BEGIN TRANSACTION;" in PHASE45
    assert "COMMIT;" in PHASE45
    assert "ROLLBACK;" in PHASE45
    assert "STATUS = 'FAILED', ENDED_AT = CURRENT_TIMESTAMP()" in PHASE45
    assert "PENDING_MEMBER_PROCESSING_FILES" in PHASE45
    assert "checkpoint.STAGE_NAME = 'MEMBER_PROCESSING'" in PHASE45


def test_arrival_order_scd2_and_redemption_deduplication_remain_unchanged() -> None:
    assert re.search(
        r"PARTITION BY member\.MEMBER_ID\s+ORDER BY member\.INGESTED_AT DESC,\s*"
        r"member\.SOURCE_FILENAME DESC,\s*member\.SOURCE_ROW_NUMBER DESC",
        PHASE45,
    )
    assert "history.COUNTRY IS DISTINCT FROM winner.COUNTRY" in PHASE45
    assert "EFFECTIVE_FROM" in PHASE45 and "EFFECTIVE_TO" in PHASE45
    assert "IS_CURRENT" in PHASE45
    assert "PARTITION BY redemption.REDEMPTION_ID" in PHASE45
    assert "redemption.INGESTED_AT DESC" in PHASE45
    assert "WHEN MATCHED AND" in PHASE45


def test_quarantine_and_country_movement_rules_are_preserved() -> None:
    assert "CREATE TABLE IF NOT EXISTS SKYPOINTS_DB.STAGING.DQ_QUARANTINE" in PHASE45
    assert "MERGE INTO SKYPOINTS_DB.STAGING.DQ_QUARANTINE AS target" in PHASE45
    assert "FAILURE_REASONS" in PHASE45
    assert "WHEN MATCHED THEN UPDATE SET\n        FAILURE_REASONS = source.FAILURE_REASONS" in PHASE45
    assert "'MEMBER_ROUTING' AS DATASET_NAME" in ROUTING
    assert "BEGIN TRANSACTION;" in ROUTING and "ROLLBACK;" in ROUTING
    assert "FAILURE_REASON IS NULL" in ROUTING
    assert "FAILURE_REASON IS NOT NULL" not in ROUTING.split(
        "DELETE FROM IDENTIFIER(:v_target_fqn)", 1
    )[1].split(";", 1)[0]
    assert "COUNTRY_MOVEMENT_AUDIT" in RECONCILIATION
    assert "movement.ACTION = 'QUARANTINED'" in RECONCILIATION
    assert "MEMBER_CURRENT_UNIQUE_MEMBER_ID" in RECONCILIATION
    assert "WHERE MEMBER_ID IS NULL" in RECONCILIATION
    assert "HAVING COUNT(*) > 1" in RECONCILIATION


def test_unified_monitoring_reports_task_failures_incremental_counts_and_core_totals() -> None:
    for metric in (
        "GRAPH_RUN_ID",
        "TASK_NAME",
        "STATE",
        "STARTED_AT",
        "ENDED_AT",
        "DURATION_SECONDS",
        "ROWS_LOADED",
        "SOURCE_FILES",
        "ROWS_PROCESSED",
        "VALID_RECORDS",
        "INVALID_RECORDS",
        "DUPLICATE_COUNT",
        "QUARANTINED_COUNT",
        "CURRENT_MEMBERS",
        "REDEMPTION_FACT_ROWS",
        "INSERTED_COUNT",
        "UPDATED_COUNT",
        "REMOVED_COUNT",
        "FAILED_CHECK_COUNT",
        "ERROR_MESSAGE",
        "FAILED_TASK_NAME",
    ):
        assert metric in PIPELINE_MONITORING
    assert "LAG(run.STATUS)" in PIPELINE_MONITORING
    assert "WHERE run.STATUS <> 'SUCCEEDED'" in PIPELINE_MONITORING
    assert "ETL_FILE_STAGE_STATUS" in PIPELINE_MONITORING


def test_unified_monitoring_limits_both_task_history_queries_to_seven_days() -> None:
    assert PIPELINE_MONITORING.count(
        "DATEADD('DAY', -7, CURRENT_TIMESTAMP())"
    ) == 2
    assert not re.search(
        r"DATEADD\s*\(\s*'DAY'\s*,\s*-30\b",
        PIPELINE_MONITORING,
        re.IGNORECASE,
    )
    assert PIPELINE_MONITORING.count(
        "FROM TABLE(SKYPOINTS_DB.INFORMATION_SCHEMA.TASK_HISTORY("
    ) == 2


def test_unified_monitoring_preserves_task_history_correlation_and_failure_details() -> None:
    assert PIPELINE_MONITORING.count("GRAPH_RUN_GROUP_ID") >= 2
    assert "run.GRAPH_RUN_ID = history.GRAPH_RUN_GROUP_ID" in PIPELINE_MONITORING
    assert "history.GRAPH_RUN_GROUP_ID = run.GRAPH_RUN_ID" in PIPELINE_MONITORING
    assert "history.STATE IN ('FAILED', 'CANCELLED', 'SKIPPED')" in PIPELINE_MONITORING
    assert "history.ERROR_MESSAGE AS TASK_ERROR" in PIPELINE_MONITORING
    assert "ingestion.ERROR_DETAILS AS INGESTION_ERROR" in PIPELINE_MONITORING
    assert "processing.ERROR_DETAILS AS PROCESSING_ERROR" in PIPELINE_MONITORING
    assert "WHERE run.STATUS <> 'SUCCEEDED'" in PIPELINE_MONITORING


def test_per_run_quarantine_counts_ignore_historical_quarantine_rows() -> None:
    per_run_dq = PIPELINE_MONITORING.split(
        "-- Per-run DQ totals", 1
    )[1].split(
        "-- Current business-table totals", 1
    )[0]
    assert "FROM SKYPOINTS_DB.AUDIT.DQ_EXECUTION AS dq" in per_run_dq
    assert "FROM SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT" in per_run_dq
    assert "COUNT(DISTINCT RECORD_KEY) AS QUARANTINED_COUNT" in per_run_dq
    assert "GROUP BY RUN_ID, DATASET_NAME" in per_run_dq
    assert "failed_records.RUN_ID = dq.RUN_ID" in per_run_dq
    assert "JOIN SKYPOINTS_DB.STAGING.DQ_QUARANTINE" not in per_run_dq
    assert "quarantine.RUN_ID" not in per_run_dq
    assert "ALL_QUARANTINED_RECORDS" in PIPELINE_MONITORING


def test_reconciliation_monitor_excludes_execution_errors_from_check_counts() -> None:
    reconciliation_query = PIPELINE_MONITORING.split(
        "-- Country operation counts", 1
    )[1].split(
        "-- Failure drill-down", 1
    )[0]
    aggregation = reconciliation_query.split(
        "SELECT\n        RUN_ID,", 1
    )[1].split(
        ") AS reconciliation", 1
    )[0]

    assert (
        "COUNT_IF(CHECK_NAME <> 'RECONCILIATION_EXECUTION')" in aggregation
    )
    assert (
        "CHECK_NAME <> 'RECONCILIATION_EXECUTION'\n"
        "                AND STATUS = 'FAILED'"
    ) in aggregation
    assert (
        "CHECK_NAME = 'RECONCILIATION_EXECUTION'\n"
        "                AND STATUS = 'FAILED'"
    ) in aggregation


def test_reconciliation_monitor_counts_individual_failures_only() -> None:
    assert re.search(
        r"COALESCE\(\s*COUNT_IF\(\s*"
        r"CHECK_NAME <> 'RECONCILIATION_EXECUTION'\s+"
        r"AND STATUS = 'FAILED'\s*\),\s*0\s*\) AS FAILED_CHECK_COUNT",
        PIPELINE_MONITORING,
    )


def test_reconciliation_execution_failure_forces_failed_overall_status() -> None:
    reconciliation_query = PIPELINE_MONITORING.split(
        "-- Country operation counts", 1
    )[1].split(
        "-- Failure drill-down", 1
    )[0]

    assert "reconciliation.EXECUTION_FAILED_COUNT > 0" in reconciliation_query
    assert "OR reconciliation.FAILED_CHECK_COUNT > 0" in reconciliation_query
    assert "'FAILED'" in reconciliation_query
    assert "reconciliation.RUN_ID IS NULL" in reconciliation_query


def test_phase7_documentation_covers_run_recovery_and_snowflake_limits() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    sql_readme = (ROOT / "sql" / "README.md").read_text(encoding="utf-8")
    for content in (readme, sql_readme):
        assert "Phase 7" in content
        assert "SP_RUN_COMPLETE_PIPELINE" in content
        assert "ETL_FILE_STAGE_STATUS" in content
        assert "monitor_unified_pipeline.sql" in content
        assert "64-day" in content or "64 days" in content
