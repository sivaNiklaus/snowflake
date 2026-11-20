from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
INGESTION = ROOT / "sql" / "ingestion"
MEMBER_COPY = (INGESTION / "load_member_profile.sql").read_text(encoding="utf-8")
REDEMPTION_COPY = (INGESTION / "load_redemption.sql").read_text(encoding="utf-8")


def test_member_copy_uses_existing_objects_and_preserves_complete_records() -> None:
    assert "COPY INTO SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW" in MEMBER_COPY
    assert "FROM @SKYPOINTS_DB.RAW.MEMBER_S3_STAGE" in MEMBER_COPY
    assert (
        "FILE_FORMAT = (FORMAT_NAME = SKYPOINTS_DB.RAW.MEMBER_PROFILE_CSV)"
        in MEMBER_COPY
    )
    assert "$1::VARCHAR" in MEMBER_COPY
    assert "$2" not in MEMBER_COPY
    assert "SPLIT(" not in MEMBER_COPY.upper()
    assert "ON_ERROR = 'ABORT_STATEMENT'" in MEMBER_COPY
    assert "FORCE" not in MEMBER_COPY.upper()


def test_redemption_copy_loads_each_complete_variant_document() -> None:
    assert "COPY INTO SKYPOINTS_DB.RAW.REDEMPTION_RAW" in REDEMPTION_COPY
    assert "FROM @SKYPOINTS_DB.RAW.REDEMPTION_S3_STAGE" in REDEMPTION_COPY
    assert (
        "FILE_FORMAT = (FORMAT_NAME = SKYPOINTS_DB.RAW.REDEMPTION_JSON)"
        in REDEMPTION_COPY
    )
    assert "$1::VARIANT" in REDEMPTION_COPY
    assert "FLATTEN" not in REDEMPTION_COPY.upper()
    assert "ON_ERROR = 'ABORT_STATEMENT'" in REDEMPTION_COPY
    assert "FORCE" not in REDEMPTION_COPY.upper()


def test_copy_scripts_project_all_ingestion_metadata() -> None:
    for sql in (MEMBER_COPY, REDEMPTION_COPY):
        for column, source in (
            ("SOURCE_FILENAME", "METADATA$FILENAME"),
            ("SOURCE_ROW_NUMBER", "METADATA$FILE_ROW_NUMBER"),
            ("SOURCE_FILE_CONTENT_KEY", "METADATA$FILE_CONTENT_KEY"),
            ("INGESTED_AT", "METADATA$START_SCAN_TIME"),
        ):
            assert column in sql
            assert source in sql


def test_validation_scripts_cover_counts_samples_metadata_and_copy_history() -> None:
    for script_name, table_name in (
        ("validate_member_profile.sql", "MEMBER_PROFILE_RAW"),
        ("validate_redemption.sql", "REDEMPTION_RAW"),
    ):
        sql = (INGESTION / script_name).read_text(encoding="utf-8")
        assert f"FROM SKYPOINTS_DB.RAW.{table_name}" in sql
        assert re.search(r"SELECT COUNT\(\*\).*?FROM", sql, flags=re.DOTALL)
        assert re.search(r"LIMIT \d+", sql)
        assert "COUNT_IF(" in sql
        assert "SOURCE_FILENAME IS NULL" in sql
        assert "INGESTED_AT IS NULL" in sql
        assert "INFORMATION_SCHEMA.COPY_HISTORY" in sql
        assert "STATUS" in sql
