from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def test_dcm_manifest_uses_supported_project_format() -> None:
    manifest = (ROOT / "manifest.yml").read_text(encoding="utf-8")

    assert re.search(r"(?m)^manifest_version:\s*2\s*$", manifest)
    assert re.search(r"(?m)^type:\s*DCM_PROJECT\s*$", manifest)
    assert re.search(r"(?m)^default_target:\s*DEV\s*$", manifest)
    assert "account_identifier:" in manifest
    assert "project_name: SKYPOINTS_DB.AUDIT.SKYPOINTS_DCM_PROJECT_DEV" in manifest
    assert "project_owner:" in manifest


def test_dcm_definitions_declare_required_foundation_objects() -> None:
    definitions = (
        ROOT / "sources" / "definitions" / "01_foundation.sql"
    ).read_text(encoding="utf-8")

    assert not re.search(r"(?im)^DEFINE DATABASE SKYPOINTS_DB\b", definitions)
    assert not re.search(
        r"(?im)^DEFINE SCHEMA SKYPOINTS_DB\.AUDIT\b",
        definitions,
    )
    for schema in ("RAW", "STAGING", "CORE", "ANALYTICS"):
        assert re.search(
            rf"(?im)^DEFINE SCHEMA SKYPOINTS_DB\.{schema}\b",
            definitions,
        )
    assert re.search(r"(?im)^DEFINE WAREHOUSE SKYPOINTS_ETL_WH\b", definitions)
    assert re.search(r"(?im)^\s*WAREHOUSE_SIZE\s*=\s*XSMALL\b", definitions)


def test_dcm_bootstrap_only_creates_project_host_schema() -> None:
    bootstrap = (ROOT / "sql" / "bootstrap_dcm.sql").read_text(encoding="utf-8")

    assert re.search(r"(?im)^CREATE DATABASE IF NOT EXISTS SKYPOINTS_DB\b", bootstrap)
    assert re.search(
        r"(?im)^CREATE SCHEMA IF NOT EXISTS SKYPOINTS_DB\.AUDIT\b",
        bootstrap,
    )
    assert "CREATE WAREHOUSE" not in bootstrap.upper()


def test_environment_example_contains_credentials_as_blank_and_default_prefixes() -> None:
    example = (ROOT / ".env.example").read_text(encoding="utf-8")
    assignments = {
        key: value
        for line in example.splitlines()
        if line and not line.startswith("#")
        for key, value in [line.split("=", maxsplit=1)]
    }

    assert all(re.fullmatch(r"[A-Z][A-Z0-9_]*", key) for key in assignments)
    assert assignments["AWS_S3_BUCKET"] == ""
    assert assignments["AWS_S3_MEMBERS_PREFIX"] == "members/"
    assert assignments["AWS_S3_REDEMPTIONS_PREFIX"] == "redemptions/"
