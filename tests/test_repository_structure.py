"""Static checks for the documented SQL repository layout."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

EXPECTED_SQL_FILES = (
    "sql/00_setup/bootstrap_dcm.sql",
    "sql/00_setup/create_s3_storage_integration.sql",
    "sql/01_ingestion/pipes/create_member_profile_pipe.sql",
    "sql/01_ingestion/pipes/create_redemption_pipe.sql",
    "sql/01_ingestion/pipes/validate_ingestion_pipes.sql",
    "sql/01_ingestion/load/load_member_profile.sql",
    "sql/01_ingestion/load/load_redemption.sql",
    "sql/01_ingestion/validate/validate_member_profile.sql",
    "sql/01_ingestion/validate/validate_redemption.sql",
    "sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql",
    "sql/02_orchestration_ingestion/execute_ingestion_task_graph.sql",
    "sql/02_orchestration_ingestion/monitor_ingestion_task_graph.sql",
    "sql/03_processing/dq_and_transformation/deploy_ingestion_dq_and_business_transformation.sql",
    "sql/03_processing/dq_and_transformation/execute_ingestion_dq_and_business_transformation.sql",
    "sql/03_processing/dq_and_transformation/monitor_ingestion_dq_and_business_transformation.sql",
    "sql/03_processing/country_routing/deploy_country_routing.sql",
    "sql/03_processing/country_routing/execute_country_routing.sql",
    "sql/03_processing/country_routing/monitor_country_routing.sql",
    "sql/03_processing/country_movement_reconciliation/deploy_country_movement_reconciliation.sql",
    "sql/04_unified_pipeline/deploy_unified_pipeline.sql",
    "sql/04_unified_pipeline/execute_unified_pipeline.sql",
    "sql/04_unified_pipeline/monitor_unified_pipeline.sql",
    "sql/05_lifecycle/suspend_pipeline_tasks.sql",
    "sql/05_lifecycle/destroy_phase7.sql",
    "sql/05_lifecycle/destroy_phase6_reconciliation.sql",
    "sql/05_lifecycle/destroy_phase6_routing.sql",
    "sql/05_lifecycle/destroy_phase45.sql",
    "sql/05_lifecycle/destroy_phase3.sql",
    "sql/05_lifecycle/destroy_pipes.sql",
)

EXPECTED_DIRECTORIES = (
    "sql/00_setup",
    "sql/01_ingestion/pipes",
    "sql/01_ingestion/load",
    "sql/01_ingestion/validate",
    "sql/02_orchestration_ingestion",
    "sql/03_processing/dq_and_transformation",
    "sql/03_processing/country_routing",
    "sql/03_processing/country_movement_reconciliation",
    "sql/04_unified_pipeline",
    "sql/05_lifecycle",
    "sources/definitions",
    "tests/fixtures/members",
    "tests/fixtures/redemptions",
    "docs",
    "config",
)


def test_expected_sql_files_exist_exactly_once_in_target_locations() -> None:
    for relative_path in EXPECTED_SQL_FILES:
        expected = ROOT / relative_path
        assert expected.is_file(), f"Missing expected SQL file: {relative_path}"
        same_name = list((ROOT / "sql").rglob(expected.name))
        assert same_name == [expected], f"Unexpected duplicate for {expected.name}: {same_name}"


def test_target_directories_exist_and_old_sql_directories_are_gone() -> None:
    for relative_path in EXPECTED_DIRECTORIES:
        assert (ROOT / relative_path).is_dir(), f"Missing directory: {relative_path}"

    for old_path in (
        "sql/ingestion",
        "sql/orchestration",
        "sql/processing",
        "src",
    ):
        assert not (ROOT / old_path).exists(), f"Obsolete directory remains: {old_path}"


def test_phase7_unified_sql_files_are_in_the_documented_ordered_tree() -> None:
    assert (ROOT / "sql/04_unified_pipeline/deploy_unified_pipeline.sql").is_file()
    assert (ROOT / "sql/04_unified_pipeline/execute_unified_pipeline.sql").is_file()
    assert (ROOT / "sql/04_unified_pipeline/monitor_unified_pipeline.sql").is_file()


def test_lifecycle_interface_and_resource_inventory_are_present() -> None:
    assert (ROOT / "sql/05_lifecycle/suspend_pipeline_tasks.sql").is_file()
    assert (ROOT / "manage.py").is_file()
    assert (ROOT / "docs/resource-inventory.md").is_file()
