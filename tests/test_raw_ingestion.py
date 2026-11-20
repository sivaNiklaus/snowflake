from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DEFINITIONS = (
    ROOT / "sources" / "definitions" / "02_raw_ingestion.sql"
).read_text(encoding="utf-8")


def test_member_pipe_preserves_twelve_source_positions_and_metadata() -> None:
    table = re.search(
        r"DEFINE TABLE SKYPOINTS_DB\.RAW\.MEMBER_PROFILE_RAW\s*\((.*?)\)\s*COMMENT",
        DEFINITIONS,
        flags=re.DOTALL,
    )
    assert table is not None
    columns = re.findall(
        r"^\s*(SOURCE_COLUMN_\d{2})\s+VARCHAR,",
        table.group(1),
        re.MULTILINE,
    )
    assert columns == [f"SOURCE_COLUMN_{number:02}" for number in range(1, 13)]
    for metadata_column in (
        "SOURCE_FILENAME",
        "SOURCE_ROW_NUMBER",
        "SOURCE_FILE_CONTENT_KEY",
        "INGESTED_AT",
    ):
        assert metadata_column in table.group(1)

    pipe = re.search(
        r"DEFINE PIPE SKYPOINTS_DB\.RAW\.MEMBER_PROFILE_PIPE(.*?)"
        r"DEFINE PIPE SKYPOINTS_DB\.RAW\.REDEMPTION_PIPE",
        DEFINITIONS,
        flags=re.DOTALL,
    )
    assert pipe is not None
    projection = re.findall(
        r"^\s*\$(\d+)::VARCHAR,?$",
        pipe.group(1),
        re.MULTILINE,
    )
    assert projection == [str(number) for number in range(1, 13)]
    for metadata_column in (
        "METADATA$FILENAME",
        "METADATA$FILE_ROW_NUMBER",
        "METADATA$FILE_CONTENT_KEY",
        "METADATA$START_SCAN_TIME",
    ):
        assert metadata_column in pipe.group(1)


def test_member_csv_does_not_skip_header_or_truncate_mismatched_rows() -> None:
    member_format = re.search(
        r"DEFINE FILE FORMAT SKYPOINTS_DB\.RAW\.MEMBER_PROFILE_CSV(.*?)"
        r"DEFINE FILE FORMAT SKYPOINTS_DB\.RAW\.REDEMPTION_JSON",
        DEFINITIONS,
        flags=re.DOTALL,
    )
    assert member_format is not None
    assert re.search(r"FIELD_DELIMITER\s*=\s*'\|'", member_format.group(1))
    assert re.search(r"SKIP_HEADER\s*=\s*0\b", member_format.group(1))
    assert re.search(
        r"ERROR_ON_COLUMN_COUNT_MISMATCH\s*=\s*TRUE",
        member_format.group(1),
    )
    assert re.search(r"EMPTY_FIELD_AS_NULL\s*=\s*FALSE", member_format.group(1))
    assert re.search(r"ON_ERROR\s*=\s*SKIP_FILE", DEFINITIONS)


def test_redemption_pipe_keeps_each_json_document_as_variant() -> None:
    assert re.search(
        r"DEFINE FILE FORMAT SKYPOINTS_DB\.RAW\.REDEMPTION_JSON"
        r".*?STRIP_OUTER_ARRAY\s*=\s*FALSE",
        DEFINITIONS,
        flags=re.DOTALL,
    )
    assert re.search(
        r"DEFINE TABLE SKYPOINTS_DB\.RAW\.REDEMPTION_RAW\s*"
        r"\(\s*PAYLOAD\s+VARIANT",
        DEFINITIONS,
    )
    assert re.search(
        r"DEFINE PIPE SKYPOINTS_DB\.RAW\.REDEMPTION_PIPE\s+"
        r"AUTO_INGEST\s*=\s*TRUE",
        DEFINITIONS,
    )
    assert len(re.findall(r"AUTO_INGEST\s*=\s*TRUE", DEFINITIONS)) == 2


def test_s3_integration_and_stage_urls_use_configurable_placeholders() -> None:
    integration = (
        ROOT / "sql" / "create_s3_storage_integration.sql"
    ).read_text(encoding="utf-8")
    assert "STORAGE_PROVIDER = 'S3'" in integration
    assert "STORAGE_AWS_ROLE_ARN = '<AWS_IAM_ROLE_ARN>'" in integration
    assert "STORAGE_ALLOWED_LOCATIONS" in integration
    assert "ENABLED = TRUE" in integration
    for placeholder in (
        "<AWS_S3_BUCKET>",
        "<AWS_S3_MEMBERS_PREFIX>",
        "<AWS_S3_REDEMPTIONS_PREFIX>",
    ):
        assert placeholder in integration
        assert placeholder in DEFINITIONS
