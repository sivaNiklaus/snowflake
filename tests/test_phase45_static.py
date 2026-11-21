"""Static contract checks for Phase 4-5 SQL; these tests do not connect to Snowflake."""

import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DEPLOYMENT = (
    ROOT / "sql" / "processing" / "deploy_ingestion_dq_and_business_transformation.sql"
).read_text(encoding="utf-8")
TASK_DEPLOYMENT = (
    ROOT / "sql" / "orchestration" / "deploy_ingestion_task_graph.sql"
).read_text(encoding="utf-8")
EXECUTION = (
    ROOT / "sql" / "orchestration" / "execute_ingestion_dq_and_business_transformation.sql"
).read_text(encoding="utf-8")
MONITORING = (
    ROOT / "sql" / "orchestration" / "monitor_ingestion_dq_and_business_transformation.sql"
).read_text(encoding="utf-8")
MEMBER_LINES = (
    ROOT / "tests" / "fixtures" / "members" / "member_sample.dat"
).read_text(encoding="utf-8").splitlines()
REDEMPTION_DOCUMENTS = [
    json.loads(line)
    for line in (
        ROOT / "tests" / "fixtures" / "redemptions" / "redemption_sample.json"
    ).read_text(encoding="utf-8").splitlines()
]


def test_member_parser_supports_both_shapes_and_excludes_headers_from_dq() -> None:
    assert [len(line.split("|")) for line in MEMBER_LINES] == [12, 12, 13, 12]
    assert MEMBER_LINES[0].split("|")[1] == "H"
    assert all(line.startswith("|D|") for line in MEMBER_LINES[1:])
    assert MEMBER_LINES[2].split("|")[3] == "23457"
    assert MEMBER_LINES[2].split("|")[12] == "75001"
    assert "SPLIT_PART(SOURCE_RECORD, '|', 13)" in DEPLOYMENT
    assert "COALESCE(member.MEMBER_RECORD_TYPE, '') <> 'H'" in DEPLOYMENT
    assert "member.MEMBER_RECORD_TYPE = 'D'" in DEPLOYMENT
    assert "SOURCE_RECORD VARCHAR NOT NULL" in DEPLOYMENT


def test_member_dates_are_safely_parsed_without_numeric_member_ids() -> None:
    assert "TRY_TO_DATE" in DEPLOYMENT
    assert "'YYYYMMDD'" in DEPLOYMENT
    assert "'MMDDYYYY'" in DEPLOYMENT
    assert "MEMBER_ID VARCHAR" in DEPLOYMENT
    assert not re.search(r"MEMBER_ID\s+NUMBER", DEPLOYMENT, flags=re.IGNORECASE)
    assert "ENROLLMENT_DATE_RAW IS NOT NULL" in DEPLOYMENT
    assert "member.DOB_RAW IS NOT NULL AND member.DOB IS NOT NULL" in DEPLOYMENT


def test_redemptions_flatten_preserve_lineage_and_ignore_empty_arrays() -> None:
    assert len(REDEMPTION_DOCUMENTS) == 2
    assert len(REDEMPTION_DOCUMENTS[0]["redemptions"]) == 2
    assert REDEMPTION_DOCUMENTS[1]["redemptions"] == []
    assert "LATERAL FLATTEN(INPUT => raw.PAYLOAD:redemptions)" in DEPLOYMENT
    assert "flattened.INDEX" in DEPLOYMENT
    assert "SOURCE_FILENAME" in DEPLOYMENT
    assert "SOURCE_ROW_NUMBER" in DEPLOYMENT
    assert "SOURCE_FILE_CONTENT_KEY" in DEPLOYMENT
    assert "INGESTED_AT" in DEPLOYMENT
    assert "ORIGINAL_PAYLOAD VARIANT" in DEPLOYMENT
    assert "OUTER => TRUE" not in DEPLOYMENT.upper()


def test_parse_procedure_uses_supported_select_into_statements() -> None:
    parse_procedure = DEPLOYMENT.split(
        "CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.STAGING.SP_PARSE_AND_NORMALIZE()",
        1,
    )[1].split(
        "CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.STAGING.SP_RUN_DQ_VALIDATION()",
        1,
    )[0]
    assert "SELECT COUNT(*)\n      INTO :v_member_rows" in parse_procedure
    assert "SELECT COUNT(*)\n      INTO :v_redemption_rows" in parse_procedure
    assert "v_rows_processed := v_member_rows + v_redemption_rows;" in parse_procedure
    assert "SELECT\n        (SELECT COUNT(*)" not in parse_procedure


def test_metadata_seeds_every_supported_dq_rule_and_maps_controlled_types() -> None:
    rules = (
        "MEMBER_ID_NOT_NULL",
        "MEMBER_NAME_NOT_NULL",
        "DOB_VALID",
        "ENROLLMENT_DATE_VALID",
        "COUNTRY_NOT_NULL",
        "IS_ACTIVE_VALID",
        "MEMBER_RECORD_TYPE_VALID",
        "REDEMPTION_ID_NOT_NULL",
        "MEMBER_ID_NOT_NULL",
        "FEED_DATE_VALID",
        "POINTS_NON_NEGATIVE",
        "STATUS_VALID",
        "MEMBER_EXISTS",
    )
    for rule in rules:
        assert f"'{rule}'" in DEPLOYMENT
    assert "CROSS JOIN SKYPOINTS_DB.AUDIT.DQ_RULE_MASTER" in DEPLOYMENT
    assert "WHEN 'MEMBER_EXISTS' THEN" in DEPLOYMENT
    assert "ELSE FALSE" in DEPLOYMENT
    assert "e_unsupported_rule EXCEPTION" in DEPLOYMENT
    assert "RULE_TYPE NOT IN" in DEPLOYMENT
    assert "EXECUTE IMMEDIATE" not in DEPLOYMENT.upper()
    assert "DQ_RULE_RESULT" in DEPLOYMENT
    assert "EVALUATED_COUNT" in DEPLOYMENT
    assert "FAILURE_COUNT" in DEPLOYMENT


def test_dq_collects_multiple_failures_and_quarantine_merges_once_per_record() -> None:
    assert DEPLOYMENT.count("ARRAY_AGG(OBJECT_CONSTRUCT(") == 3
    assert "GROUP BY member.RECORD_KEY" in DEPLOYMENT
    assert "GROUP BY redemption.RECORD_KEY" in DEPLOYMENT
    assert DEPLOYMENT.count("target.DATASET_NAME = source.DATASET_NAME") >= 2
    assert DEPLOYMENT.count("target.RECORD_KEY = source.RECORD_KEY") >= 2
    assert "FAILURE_REASONS VARIANT NOT NULL" in DEPLOYMENT
    assert "PRIMARY KEY (DATASET_NAME, RECORD_KEY)" in DEPLOYMENT
    assert "WHEN MATCHED THEN UPDATE SET\n        FAILURE_REASONS = source.FAILURE_REASONS" in DEPLOYMENT
    assert "INVALID_RECORDS" in DEPLOYMENT
    assert "DUPLICATE_COUNT" in DEPLOYMENT
    assert "COUNT_IF(result.STATUS = 'FAILED')" in DEPLOYMENT
    assert "AND NOT EXISTS\n          (\n              SELECT 1\n              FROM SKYPOINTS_DB.CORE.MEMBER_CURRENT" in DEPLOYMENT
    assert "AND failed_rule.STATUS = 'FAILED'" in DEPLOYMENT
    dq_procedure = DEPLOYMENT.split(
        "CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.STAGING.SP_RUN_DQ_VALIDATION()",
        1,
    )[1].split(
        "CREATE OR REPLACE PROCEDURE SKYPOINTS_DB.CORE.SP_PROCESS_MEMBERS()",
        1,
    )[0]
    assert "IF (v_member_invalid" not in dq_procedure
    assert "IF (v_redemption_invalid" not in dq_procedure


def test_member_duplicates_are_observed_and_latest_valid_arrival_wins() -> None:
    assert "PARTITION BY member.MEMBER_ID" in DEPLOYMENT
    assert re.search(
        r"ORDER BY member\.INGESTED_AT DESC,\s*"
        r"member\.SOURCE_FILENAME DESC,\s*"
        r"member\.SOURCE_ROW_NUMBER DESC",
        DEPLOYMENT,
    )
    assert "member.SOURCE_FILE_CONTENT_KEY DESC" in DEPLOYMENT
    assert "member.SOURCE_RECORD DESC" in DEPLOYMENT
    assert "GROUP BY MEMBER_ID" in DEPLOYMENT
    assert "MEMBER_ID_NOT_NULL" in DEPLOYMENT
    assert "DUPLICATE_MEMBER" not in DEPLOYMENT


def test_member_history_tracks_country_changes_without_unchanged_versions() -> None:
    assert "CORE.MEMBER_CURRENT" in DEPLOYMENT
    assert "CORE.MEMBER_HISTORY" in DEPLOYMENT
    assert "history.COUNTRY IS DISTINCT FROM winner.COUNTRY" in DEPLOYMENT
    assert "EFFECTIVE_FROM" in DEPLOYMENT
    assert "EFFECTIVE_TO" in DEPLOYMENT
    assert "IS_CURRENT" in DEPLOYMENT
    assert "WHEN NOT MATCHED THEN INSERT" in DEPLOYMENT
    assert "WHERE NOT EXISTS\n    (\n        SELECT 1\n        FROM SKYPOINTS_DB.CORE.MEMBER_HISTORY" in DEPLOYMENT
    assert "DATEDIFF(YEAR, member.DOB, CURRENT_DATE())" in DEPLOYMENT
    assert "member.LAST_FLIGHT_DATE < DATEADD(DAY, -90, CURRENT_DATE())" in DEPLOYMENT
    assert "member.LAST_FLIGHT_DATE IS NULL" in DEPLOYMENT


def test_redemptions_deduplicate_and_merge_only_valid_member_linked_rows() -> None:
    assert "PARTITION BY redemption.REDEMPTION_ID" in DEPLOYMENT
    assert "redemption.INGESTED_AT DESC" in DEPLOYMENT
    assert "redemption.SOURCE_FILENAME DESC" in DEPLOYMENT
    assert "redemption.SOURCE_ROW_NUMBER DESC" in DEPLOYMENT
    assert "CORE.MEMBER_CURRENT AS current_member" in DEPLOYMENT
    assert "CORE.REDEMPTION_FACT AS target" in DEPLOYMENT
    assert "target.REDEMPTION_ID = source.REDEMPTION_ID" in DEPLOYMENT
    assert "DQ_RULE_RESULT" in DEPLOYMENT
    assert "ORIGINAL_PAYLOAD" in DEPLOYMENT
    assert "WHEN MATCHED AND" in DEPLOYMENT


def test_task_graph_extends_phase3_and_remains_manual_and_unscheduled() -> None:
    expected = [
        "TASK_PARSE_AND_NORMALIZE",
        "TASK_DQ_VALIDATION",
        "TASK_MEMBER_PROCESSING",
        "TASK_REDEMPTION_PROCESSING",
    ]
    task_names = re.findall(
        r"CREATE OR REPLACE TASK SKYPOINTS_DB\.RAW\.(TASK_\w+)",
        DEPLOYMENT,
        flags=re.IGNORECASE,
    )
    assert task_names == expected
    assert "AFTER SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION" in DEPLOYMENT
    assert "AFTER SKYPOINTS_DB.RAW.TASK_PARSE_AND_NORMALIZE" in DEPLOYMENT
    assert "AFTER SKYPOINTS_DB.RAW.TASK_DQ_VALIDATION" in DEPLOYMENT
    assert "AFTER SKYPOINTS_DB.RAW.TASK_MEMBER_PROCESSING" in DEPLOYMENT
    assert DEPLOYMENT.count("WAREHOUSE = 'SKYPOINTS_ETL_WH'") == 4
    assert "SCHEDULE =" not in DEPLOYMENT.upper()
    assert "ALTER TASK SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION SUSPEND" in DEPLOYMENT
    assert "ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION SUSPEND" in DEPLOYMENT
    assert "ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION SUSPEND" in DEPLOYMENT
    for task_name in expected:
        assert f"ALTER TASK SKYPOINTS_DB.RAW.{task_name} RESUME" not in DEPLOYMENT
    assert "ALTER TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION RESUME" not in DEPLOYMENT
    assert TASK_DEPLOYMENT.count("CREATE OR REPLACE TASK") == 3
    assert "TASK_MEMBER_INGESTION RESUME" not in TASK_DEPLOYMENT
    assert EXECUTION.index("TASK_REDEMPTION_PROCESSING RESUME") < EXECUTION.index(
        "TASK_MEMBER_PROCESSING RESUME"
    )
    assert EXECUTION.index("TASK_REDEMPTION_INGESTION RESUME") < EXECUTION.index(
        "EXECUTE TASK"
    )
    assert "TASK_REDEMPTION_PROCESSING SUSPEND" in EXECUTION
    assert EXECUTION.count("EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT") == 1
    assert "TASK_DQ_VALIDATION" in MONITORING


def test_processing_procedures_audit_retries_and_reraise_technical_errors() -> None:
    assert DEPLOYMENT.count("SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')") == 4
    assert DEPLOYMENT.count("STATUS = 'FAILED'") >= 5
    assert DEPLOYMENT.count("RAISE;") == 4
    assert "ERROR_DETAILS = :SQLERRM" in DEPLOYMENT
    assert "BEGIN TRANSACTION;" in DEPLOYMENT
    assert "COMMIT;" in DEPLOYMENT
    assert "ROLLBACK;" in DEPLOYMENT
    assert "MERGE INTO SKYPOINTS_DB.AUDIT.PHASE45_AUDIT" in DEPLOYMENT
    assert "PRIMARY KEY (RUN_ID, TASK_NAME)" in DEPLOYMENT
