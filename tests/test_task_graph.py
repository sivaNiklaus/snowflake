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
VALIDATION_PROCEDURE = DEPLOYMENT.split(
    "CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.RAW.SP_RUN_INGESTION_VALIDATION()"
)[1].split("CREATE OR REPLACE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION")[0]


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


def test_deployment_resumes_children_and_keeps_root_suspended() -> None:
    assert DEPLOYMENT.count("CREATE OR REPLACE TASK") == 3
    assert "SCHEDULE =" not in DEPLOYMENT.upper()
    resume_statements = re.findall(
        r"ALTER TASK (SKYPOINTS_DB\.RAW\.\w+) RESUME;",
        DEPLOYMENT,
        flags=re.IGNORECASE,
    )
    assert resume_statements == [
        "SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION",
        "SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION",
    ]
    assert (
        "ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION RESUME"
        not in DEPLOYMENT
    )


def test_create_task_clauses_follow_snowflake_syntax_order() -> None:
    task_statements = re.findall(
        r"CREATE OR REPLACE TASK\s+.*?\nAS\s+CALL\s+[^;]+;",
        DEPLOYMENT,
        flags=re.IGNORECASE | re.DOTALL,
    )
    assert len(task_statements) == 3

    for statement in task_statements:
        warehouse_position = statement.index("WAREHOUSE =")
        comment_position = statement.index("COMMENT =")
        as_position = statement.index("\nAS")
        assert warehouse_position < comment_position < as_position

        task_name = re.search(
            r"CREATE OR REPLACE TASK\s+([\w.]+)",
            statement,
            flags=re.IGNORECASE,
        )
        assert task_name is not None
        if not task_name.group(1).endswith(".TASK_MEMBER_INGESTION"):
            after_position = statement.index("AFTER SKYPOINTS_DB.RAW.")
            assert comment_position < after_position < as_position
        else:
            assert "AFTER " not in statement


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
    assert DEPLOYMENT.count(
        "SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')"
    ) == 3
    assert DEPLOYMENT.count("v_copy_query_id := SQLID;") == 2
    assert "v_copy_query_id := LAST_QUERY_ID();" not in DEPLOYMENT
    assert DEPLOYMENT.count("RESULT_SCAN(:v_copy_query_id)") == 2


def test_copy_result_scan_extracts_columns_without_case_sensitive_identifiers() -> None:
    assert DEPLOYMENT.count(
        "GET_IGNORE_CASE(OBJECT_CONSTRUCT(*), 'rows_loaded')::NUMBER"
    ) == 2
    assert DEPLOYMENT.count(
        "GET_IGNORE_CASE(OBJECT_CONSTRUCT(*), 'file')"
    ) == 4
    assert DEPLOYMENT.count("ARRAY_AGG(DISTINCT CASE") == 2
    assert " FILTER (WHERE " not in DEPLOYMENT.upper()
    assert 'SUM("rows_loaded")' not in DEPLOYMENT
    assert '"file"' not in DEPLOYMENT


def test_audit_inserts_use_select_for_scripting_bind_variables() -> None:
    insert_modes = re.findall(
        r"INSERT INTO SKYPOINTS_DB\.AUDIT\.INGESTION_AUDIT\s*"
        r"\([^)]*\)\s*(SELECT|VALUES)\b",
        DEPLOYMENT,
        flags=re.IGNORECASE | re.DOTALL,
    )
    assert insert_modes == ["SELECT", "SELECT", "SELECT"]
    assert "PARSE_JSON(" not in DEPLOYMENT.upper()
    assert not re.search(
        r"INSERT\s+INTO\b.*?\bVALUES\s*\(",
        DEPLOYMENT,
        flags=re.IGNORECASE | re.DOTALL,
    )
    assert DEPLOYMENT.count(":v_source_files;") == 2


def test_validation_fails_for_empty_member_table() -> None:
    assert "v_member_row_count = 0" in VALIDATION_PROCEDURE
    assert "member_row_count=" in VALIDATION_PROCEDURE


def test_validation_fails_for_empty_redemption_table() -> None:
    assert "v_redemption_row_count = 0" in VALIDATION_PROCEDURE
    assert "redemption_row_count=" in VALIDATION_PROCEDURE


def test_validation_audits_meaningful_failure_details_and_reraises() -> None:
    assert "member_invalid_count=" in VALIDATION_PROCEDURE
    assert "redemption_invalid_count=" in VALIDATION_PROCEDURE
    assert "ERROR_DETAILS = COALESCE(:v_error_details, :SQLERRM)" in VALIDATION_PROCEDURE
    assert "RAISE e_validation_failed;" in VALIDATION_PROCEDURE
    assert "RAISE;" in VALIDATION_PROCEDURE


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
        assert check in VALIDATION_PROCEDURE


def test_execution_and_monitoring_scripts_cover_manual_operation() -> None:
    assert (
        "EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT"
        in EXECUTION
    )
    assert "ALTER TASK" not in EXECUTION.upper()
    assert "TASK_HISTORY(" in MONITORING
    assert "SKYPOINTS_DB.AUDIT.INGESTION_AUDIT" in MONITORING
