import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DEFINITIONS = (
    ROOT / "sources" / "definitions" / "02_raw_ingestion.sql"
).read_text(encoding="utf-8")
MEMBER_PIPE = (
    ROOT / "sql" / "01_ingestion" / "pipes" / "create_member_profile_pipe.sql"
).read_text(encoding="utf-8")
REDEMPTION_PIPE = (
    ROOT / "sql" / "01_ingestion" / "pipes" / "create_redemption_pipe.sql"
).read_text(encoding="utf-8")
MEMBER_FIXTURE = ROOT / "tests" / "fixtures" / "members" / "member_sample.dat"
REDEMPTION_FIXTURE = (
    ROOT / "tests" / "fixtures" / "redemptions" / "redemption_sample.json"
)


def test_member_records_preserve_complete_lines_and_record_indicators() -> None:
    lines = MEMBER_FIXTURE.read_text(encoding="utf-8").splitlines()
    assert lines[0].startswith("|H|")
    assert all(line.startswith("|D|") for line in lines[1:])
    assert all(line.startswith("|") for line in lines)

    copy_projection = re.search(
        r"SELECT\s+(.*?)\s+FROM @SKYPOINTS_DB\.RAW\.MEMBER_S3_STAGE",
        MEMBER_PIPE,
        flags=re.DOTALL,
    )
    assert copy_projection is not None
    expressions = [expression.strip() for expression in copy_projection.group(1).split(",")]
    assert expressions[0] == "$1::VARCHAR"
    assert "SPLIT" not in copy_projection.group(1).upper()
    assert "FLATTEN" not in copy_projection.group(1).upper()


def test_member_format_preserves_variable_field_counts_and_post_code_variation() -> None:
    lines = MEMBER_FIXTURE.read_text(encoding="utf-8").splitlines()
    field_counts = [len(line.split("|")) for line in lines]
    assert field_counts == [12, 12, 13, 12]

    shorter_member_id = lines[2].split("|")[3]
    assert shorter_member_id == "23457"
    assert len(shorter_member_id) < len("223457")
    assert lines[2].endswith("|75001")

    member_format = re.search(
        r"DEFINE FILE FORMAT SKYPOINTS_DB\.RAW\.MEMBER_PROFILE_CSV(.*?)"
        r"DEFINE FILE FORMAT SKYPOINTS_DB\.RAW\.REDEMPTION_JSON",
        DEFINITIONS,
        flags=re.DOTALL,
    )
    assert member_format is not None
    assert re.search(r"FIELD_DELIMITER\s*=\s*NONE\b", member_format.group(1))
    assert re.search(r"SKIP_HEADER\s*=\s*0\b", member_format.group(1))
    assert re.search(r"MULTI_LINE\s*=\s*FALSE\b", member_format.group(1))
    assert re.search(
        r"ESCAPE_UNENCLOSED_FIELD\s*=\s*NONE\b",
        member_format.group(1),
    )


def test_raw_tables_and_pipes_define_required_metadata_projections() -> None:
    metadata = {
        "SOURCE_FILENAME": "VARCHAR",
        "SOURCE_ROW_NUMBER": "NUMBER",
        "SOURCE_FILE_CONTENT_KEY": "VARCHAR",
        "INGESTED_AT": "TIMESTAMP_LTZ",
    }
    member_table = re.search(
        r"DEFINE TABLE SKYPOINTS_DB\.RAW\.MEMBER_PROFILE_RAW\s*\((.*?)\)\s*COMMENT",
        DEFINITIONS,
        flags=re.DOTALL,
    )
    redemption_table = re.search(
        r"DEFINE TABLE SKYPOINTS_DB\.RAW\.REDEMPTION_RAW\s*\((.*?)\)\s*COMMENT",
        DEFINITIONS,
        flags=re.DOTALL,
    )
    assert member_table is not None
    assert redemption_table is not None
    assert re.search(r"\bSOURCE_RECORD\s+VARCHAR\b", member_table.group(1))
    assert re.search(r"\bPAYLOAD\s+VARIANT\b", redemption_table.group(1))

    for column, data_type in metadata.items():
        assert re.search(rf"\b{column}\s+{data_type}\b", member_table.group(1))
        assert re.search(rf"\b{column}\s+{data_type}\b", redemption_table.group(1))

    for pipe in (MEMBER_PIPE, REDEMPTION_PIPE):
        for projection in (
            "METADATA$FILENAME",
            "METADATA$FILE_ROW_NUMBER",
            "METADATA$FILE_CONTENT_KEY",
            "METADATA$START_SCAN_TIME",
        ):
            assert projection in pipe


def test_json_documents_are_preserved_without_flattening() -> None:
    documents = [
        json.loads(line)
        for line in REDEMPTION_FIXTURE.read_text(encoding="utf-8").splitlines()
    ]
    assert len(documents) == 2
    assert [item["status"] for item in documents[0]["redemptions"]] == [
        "COMPLETED",
        "PENDING",
    ]
    assert documents[1]["redemptions"] == []

    projection = re.search(
        r"SELECT\s+(.*?)\s+FROM @SKYPOINTS_DB\.RAW\.REDEMPTION_S3_STAGE",
        REDEMPTION_PIPE,
        flags=re.DOTALL,
    )
    assert projection is not None
    assert projection.group(1).strip().startswith("$1::VARIANT")
    assert "FLATTEN" not in projection.group(1).upper()


def test_pipes_are_independent_standalone_definitions_not_dcm_objects() -> None:
    assert "DEFINE PIPE" not in DEFINITIONS.upper()
    assert "CREATE PIPE IF NOT EXISTS SKYPOINTS_DB.RAW.MEMBER_PROFILE_PIPE" in MEMBER_PIPE
    assert "CREATE PIPE IF NOT EXISTS SKYPOINTS_DB.RAW.REDEMPTION_PIPE" in REDEMPTION_PIPE
    assert "AUTO_INGEST = TRUE" in MEMBER_PIPE
    assert "AUTO_INGEST = TRUE" in REDEMPTION_PIPE
    assert "MEMBER_PROFILE_PIPE" not in REDEMPTION_PIPE
    assert "REDEMPTION_PIPE" not in MEMBER_PIPE
