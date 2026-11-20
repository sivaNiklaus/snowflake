from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
ORCHESTRATION = ROOT / "sql" / "orchestration"
DEPLOYMENT = (
    ORCHESTRATION / "deploy_ingestion_task_graph.sql"
).read_text(encoding="utf-8")
EXECUTION = (
    ORCHESTRATION / "execute_ingestion_task_graph.sql"
).read_text(encoding="utf-8")
MONITORING = (
    ORCHESTRATION / "monitor_ingestion_task_graph.sql"
).read_text(encoding="utf-8")


def test_task_graph_has_three_fully_qualified_tasks_in_dependency_order() -> None:
    task_names = re.findall(
        r"CREATE OR REPLACE TASK (SKYPOINTS_DB\.RAW\.\w+)",
        DEPLOYMENT,
        flags=re.IGNORECASE,
    )
    assert task_names == [
        "SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION",
        "SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION",
        "SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION",
    ]
    assert "WAREHOUSE = 'SKYPOINTS_ETL_WH'" in DEPLOYMENT
    assert (
        "AFTER SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION"
        in DEPLOYMENT
    )
    assert (
        "AFTER SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION"
        in DEPLOYMENT
    )


def test_deployment_leaves_the_graph_suspended_and_without_a_schedule() -> None:
    assert DEPLOYMENT.count("CREATE OR REPLACE TASK") == 3
    assert "SCHEDULE =" not in DEPLOYMENT.upper()
    assert "ALTER TASK" not in DEPLOYMENT.upper()
    assert "RESUME" not in DEPLOYMENT.upper()


def test_ingestion_procedures_reuse_copy_logic_and_audit_failures() -> None:
    for sql, stage, target, file_format, value_projection in (
        (
            DEPLOYMENT,
            "MEMBER_S3_STAGE",
            "MEMBER_PROFILE_RAW",
            "MEMBER_PROFILE_CSV",
            "$1::VARCHAR",
        ),
        (
            DEPLOYMENT,
            "REDEMPTION_S3_STAGE",
            "REDEMPTION_RAW",
            "REDEMPTION_JSON",
            "$1::VARIANT",
        ),
    ):
        assert f"COPY INTO SKYPOINTS_DB.RAW.{target}" in sql
        assert f"FROM @SKYPOINTS_DB.RAW.{stage}" in sql
        assert f"FORMAT_NAME = SKYPOINTS_DB.RAW.{file_format}" in sql
        assert value_projection in sql
        assert "ON_ERROR = 'ABORT_STATEMENT'" in sql
        assert "METADATA$FILENAME" in sql
        assert "METADATA$FILE_ROW_NUMBER" in sql
        assert "METADATA$FILE_CONTENT_KEY" in sql
        assert "METADATA$START_SCAN_TIME" in sql

    assert "FORCE = TRUE" not in DEPLOYMENT.upper()
    assert DEPLOYMENT.count("STATUS = 'FAILED'") == 3
    assert DEPLOYMENT.count("RAISE;") == 3
    assert (
        "SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')"
        in DEPLOYMENT
    )


def test_audit_and_validation_capture_counts_sources_and_critical_nulls() -> None:
    for field in (
        "RUN_ID VARCHAR",
        "TASK_NAME VARCHAR",
        "STARTED_AT TIMESTAMP_LTZ",
        "ENDED_AT TIMESTAMP_LTZ",
        "STATUS VARCHAR",
        "ROWS_LOADED NUMBER",
        "MEMBER_ROW_COUNT NUMBER",
        "REDEMPTION_ROW_COUNT NUMBER",
        "SOURCE_FILES VARIANT",
        "ERROR_DETAILS VARCHAR",
    ):
        assert field in DEPLOYMENT

    for check in (
        "SOURCE_RECORD IS NULL",
        "PAYLOAD IS NULL",
        "SOURCE_FILENAME IS NULL",
        "SOURCE_ROW_NUMBER IS NULL",
        "SOURCE_FILE_CONTENT_KEY IS NULL",
        "INGESTED_AT IS NULL",
    ):
        assert check in DEPLOYMENT


def test_execution_and_monitoring_scripts_cover_manual_operation() -> None:
    assert (
        "ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION RESUME"
        in EXECUTION
    )
    assert (
        "ALTER TASK SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION RESUME"
        in EXECUTION
    )
    assert (
        "EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT"
        in EXECUTION
    )
    assert (
        "ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION RESUME"
        not in EXECUTION
    )
    assert "TASK_HISTORY(" in MONITORING
    assert "SKYPOINTS_DB.AUDIT.INGESTION_AUDIT" in MONITORING
