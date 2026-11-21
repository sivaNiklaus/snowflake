"""Mocked lifecycle tests; these never connect to Snowflake."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import re
import shutil
import subprocess

import pytest
import yaml

import manage


ROOT = Path(__file__).resolve().parents[1]


def configured_dev_root(tmp_path: Path) -> Path:
    shutil.copy(ROOT / "manifest.yml", tmp_path / "manifest.yml")
    (tmp_path / "config").mkdir()
    config = yaml.safe_load((ROOT / "config" / "dev.yml").read_text(encoding="utf-8"))
    config["snowflake"]["connection_name"] = "mock-dev"
    (tmp_path / "config" / "dev.yml").write_text(
        yaml.safe_dump(config, sort_keys=False),
        encoding="utf-8",
    )
    shutil.copytree(ROOT / "sources", tmp_path / "sources")
    shutil.copytree(ROOT / "sql" / "00_setup", tmp_path / "sql" / "00_setup")
    return tmp_path


class MockSnow:
    def __init__(
        self,
        plan_output: str = "Plan contains changes.",
        teardown: bool = True,
        fail_script: str | None = None,
        existing_pipe: str | None = None,
        missing_dcm_project: bool = False,
    ) -> None:
        self.plan_output = plan_output
        self.teardown = teardown
        self.fail_script = fail_script
        self.existing_pipe = existing_pipe
        self.missing_dcm_project = missing_dcm_project
        self.calls: list[list[str]] = []
        self.preflight_sql = ""

    @staticmethod
    def _result(args: list[str], output: str = "", code: int = 0, error: str = ""):
        return subprocess.CompletedProcess(args, code, output, error)

    def __call__(self, args: list[str], **_kwargs):
        self.calls.append(args)
        command = args[1:]
        if command == ["--version"]:
            return self._result(args, "Snowflake CLI 3.34.0")
        if command == ["--help"]:
            return self._result(args, "Snowflake CLI options")
        if command == ["sql", "--help"]:
            return self._result(
                args,
                "Options:\n  --connection TEXT\n  --filename FILE",
            )
        if command == ["dcm", "--help"]:
            commands = "  create  Create project\n  plan  Plan project\n  deploy  Deploy project\n"
            if self.teardown:
                commands += "  destroy  Remove deployed project resources\n"
            return self._result(
                args,
                "Options:\n  --connection TEXT\nCommands:\n" + commands,
            )
        if len(command) == 3 and command[0] == "dcm" and command[2] == "--help":
            verb = command[1]
            flags = "--target TARGET\n--connection NAME\n"
            if verb in {"create", "plan", "deploy"}:
                flags += "--from PATH\n"
            elif verb == "destroy" and self.teardown:
                flags += "--from PATH\n"
            return self._result(args, f"Options:\n{flags}")
        if len(command) >= 2 and command[0] == "dcm":
            verb = command[1]
            if verb == "plan":
                return self._result(args, self.plan_output)
            if verb == "destroy" and self.missing_dcm_project:
                return self._result(args, code=1, error="Project not found")
            return self._result(args, f"{verb} complete")
        if command[:2] == ["sql", "--connection"]:
            if "--filename" not in command:
                raise AssertionError(f"Unexpected snow sql arguments: {command}")
            script = command[command.index("--filename") + 1]
            if script.endswith("--help"):
                return self._result(args, "Options:\n  --connection NAME\n  --filename FILE")
            if "/skypoints-lifecycle-" in script.replace("\\", "/"):
                self.preflight_sql = Path(script).read_text(encoding="utf-8")
            if self.fail_script and script.replace("\\", "/").endswith(self.fail_script):
                return self._result(args, code=1, error="mock SQL failure")
            if (
                self.existing_pipe
                and script.replace("\\", "/").endswith(self.existing_pipe)
            ):
                return self._result(args, code=1, error="Pipe already exists")
            return self._result(args, "SQL completed")
        if command[:2] == ["sql", "--help"]:
            return self._result(args, "Options:\n  --connection NAME\n  --filename FILE")
        raise AssertionError(f"Unexpected Snowflake CLI invocation: {command}")


def make_manager(
    tmp_path: Path,
    fake_snow: MockSnow,
    output: list[str] | None = None,
) -> manage.LifecycleManager:
    root = configured_dev_root(tmp_path)
    target = manage.load_target_config("dev", root=root)
    return manage.LifecycleManager(
        target,
        runner=fake_snow,
        output=(output if output is not None else []).append,
        executable="snow",
        root=ROOT,
    )


def sql_filenames(fake_snow: MockSnow) -> list[str]:
    result = []
    for call in fake_snow.calls:
        args = call[1:]
        if args[:2] == ["sql", "--connection"] and "--filename" in args:
            path = args[args.index("--filename") + 1].replace("\\", "/")
            if "/skypoints-lifecycle-" not in path:
                result.append(path)
    return result


def dcm_actions(fake_snow: MockSnow) -> list[str]:
    return [
        call[2]
        for call in fake_snow.calls
        if len(call) > 2
        and call[1:2] == ["dcm"]
        and call[2] in {"create", "plan", "deploy", "destroy"}
        and call[-1] != "--help"
    ]


def test_target_config_checks_dev_placeholders_and_target_definition() -> None:
    with pytest.raises(manage.LifecycleError, match="connection_name"):
        manage.load_target_config("dev")

    with pytest.raises(manage.LifecycleError, match="no matching target"):
        manage.load_target_config("staging")
    with pytest.raises(manage.LifecycleError, match="no matching target"):
        manage.load_target_config("prod")


def test_valid_dev_configuration_matches_manifest_and_stage_resources(tmp_path: Path) -> None:
    root = configured_dev_root(tmp_path)
    target = manage.load_target_config("dev", root=root)

    assert target.manifest_target == "DEV"
    assert target.connection_name == "mock-dev"
    assert target.storage_integration == "SKYPOINTS_S3_STORAGE_INT"
    assert target.s3_bucket == "skypoints-etl-dev-siva-0408"
    assert target.delete_warehouse is True


def test_deploy_orders_dcm_and_standalone_sql_without_running_pipeline(
    tmp_path: Path,
) -> None:
    fake = MockSnow()
    manager = make_manager(tmp_path, fake)

    manager.deploy()

    assert dcm_actions(fake) == ["create", "plan", "deploy"]
    assert sql_filenames(fake) == [
        "sql/01_ingestion/pipes/create_member_profile_pipe.sql",
        "sql/01_ingestion/pipes/create_redemption_pipe.sql",
        "sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql",
        "sql/03_processing/dq_and_transformation/deploy_ingestion_dq_and_business_transformation.sql",
        "sql/03_processing/country_routing/deploy_country_routing.sql",
        "sql/03_processing/country_movement_reconciliation/deploy_country_movement_reconciliation.sql",
        "sql/04_unified_pipeline/deploy_unified_pipeline.sql",
        "sql/05_lifecycle/suspend_pipeline_tasks.sql",
    ]
    assert not any("execute_unified_pipeline.sql" in path for path in sql_filenames(fake))
    assert manager.completed[-1] == "Suspend all pipeline tasks"
    assert "DESC DATABASE SKYPOINTS_DB" in fake.preflight_sql
    assert "DESC SCHEMA SKYPOINTS_DB.AUDIT" in fake.preflight_sql
    assert "DESC INTEGRATION SKYPOINTS_S3_STORAGE_INT" in fake.preflight_sql
    assert "CURRENT_ROLE() <> 'ACCOUNTADMIN'" in fake.preflight_sql


def test_deploy_skips_dcm_deploy_when_plan_is_up_to_date(tmp_path: Path) -> None:
    fake = MockSnow(plan_output="No changes detected.")
    manager = make_manager(tmp_path, fake)

    manager.deploy()

    assert dcm_actions(fake) == ["create", "plan"]
    assert "DCM deploy (plan reports no changes)" in manager.skipped


def test_deploy_refuses_dcm_syntax_not_documented_by_installed_help(
    tmp_path: Path,
) -> None:
    class MissingDcmFlagSnow(MockSnow):
        def __call__(self, args: list[str], **kwargs):
            if args[1:] == ["dcm", "create", "--help"]:
                self.calls.append(args)
                return self._result(args, "Options:\n  --target TARGET")
            return super().__call__(args, **kwargs)

    fake = MissingDcmFlagSnow()
    manager = make_manager(tmp_path, fake)

    with pytest.raises(manage.LifecycleError, match="does not document required options"):
        manager.deploy()

    assert dcm_actions(fake) == []


@pytest.mark.parametrize(
    ("method_name", "expected_script"),
    (
        ("run_pipeline", "sql/04_unified_pipeline/execute_unified_pipeline.sql"),
        ("monitor", "sql/04_unified_pipeline/monitor_unified_pipeline.sql"),
    ),
)
def test_run_and_monitor_use_separate_unified_scripts(
    tmp_path: Path,
    method_name: str,
    expected_script: str,
) -> None:
    fake = MockSnow()
    manager = make_manager(tmp_path, fake)

    getattr(manager, method_name)()

    assert sql_filenames(fake) == [expected_script]
    assert dcm_actions(fake) == []


def test_deploy_failure_stops_and_reports_completed_steps(tmp_path: Path) -> None:
    output: list[str] = []
    fake = MockSnow(fail_script="sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql")
    manager = make_manager(tmp_path, fake, output)

    with pytest.raises(manage.LifecycleError, match="mock SQL failure"):
        manager.deploy()

    assert "sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql" in sql_filenames(fake)
    assert not any("03_processing" in path for path in sql_filenames(fake))
    assert any("Member auto-ingest pipe" in step for step in manager.completed)
    assert any("Deployment stopped" in line for line in output)


def test_existing_pipe_is_left_unchanged_and_deploy_continues(tmp_path: Path) -> None:
    fake = MockSnow(existing_pipe="create_member_profile_pipe.sql")
    manager = make_manager(tmp_path, fake)

    manager.deploy()

    assert any("existing pipe was not replaced" in item for item in manager.skipped)
    assert manager.completed[-1] == "Suspend all pipeline tasks"


def test_destroy_suspends_and_drops_in_reverse_dependency_order(tmp_path: Path) -> None:
    fake = MockSnow()
    manager = make_manager(tmp_path, fake)

    manager.destroy(yes=True)

    expected_sql = [script for _, script in manage.DESTROY_SQL_SEQUENCE]
    assert sql_filenames(fake) == expected_sql
    assert dcm_actions(fake) == ["destroy"]
    assert manager.completed[-1] == "Destroy DCM-managed resources"


def test_destroy_refuses_before_deletion_when_dcm_help_lacks_teardown(
    tmp_path: Path,
) -> None:
    output: list[str] = []
    fake = MockSnow(teardown=False)
    manager = make_manager(tmp_path, fake, output)

    with pytest.raises(manage.LifecycleError, match="does not advertise"):
        manager.destroy(yes=True)

    assert sql_filenames(fake) == []
    assert "Always protected:" in "\n".join(output)


def test_destroy_stops_on_failure_and_does_not_run_later_phases(tmp_path: Path) -> None:
    fake = MockSnow(fail_script="sql/05_lifecycle/destroy_phase45.sql")
    manager = make_manager(tmp_path, fake)

    with pytest.raises(manage.LifecycleError, match="mock SQL failure"):
        manager.destroy(yes=True)

    assert sql_filenames(fake) == [
        "sql/05_lifecycle/suspend_pipeline_tasks.sql",
        "sql/05_lifecycle/destroy_phase7.sql",
        "sql/05_lifecycle/destroy_phase6_reconciliation.sql",
        "sql/05_lifecycle/destroy_phase6_routing.sql",
        "sql/05_lifecycle/destroy_phase45.sql",
    ]
    assert dcm_actions(fake) == []


def test_missing_dcm_project_is_a_safe_destroy_skip(tmp_path: Path) -> None:
    fake = MockSnow(missing_dcm_project=True)
    manager = make_manager(tmp_path, fake)

    manager.destroy(yes=True)

    assert "DCM resources/project already absent" in manager.skipped


def test_destroy_respects_target_warehouse_policy_before_cli_invocation(
    tmp_path: Path,
) -> None:
    fake = MockSnow()
    manager = make_manager(tmp_path, fake)
    manager.target = replace(manager.target, delete_warehouse=False)

    with pytest.raises(manage.LifecycleError, match="policy does not permit"):
        manager.destroy(yes=True)

    assert fake.calls == []


def test_destroy_confirmation_and_production_safeguard() -> None:
    dev = manage.TargetConfig(
        "dev", "DEV", "c", "SKYPOINTS_DB", "WH", "INT", "bucket",
        "members/", "redemptions/", "DB.AUDIT.PROJECT", "ACCOUNTADMIN", True,
    )
    manage.require_destroy_confirmation(
        dev, False, "dev", False, input_fn=lambda _prompt: "unused"
    )
    with pytest.raises(manage.LifecycleError, match="did not match"):
        manage.require_destroy_confirmation(
            dev, False, "wrong", False, input_fn=lambda _prompt: "wrong"
        )

    prod = manage.TargetConfig(
        "prod", "PROD", "c", "DB", "WH", "INT", "bucket",
        "members/", "redemptions/", "DB.AUDIT.PROD", "ACCOUNTADMIN", True,
    )
    with pytest.raises(manage.LifecycleError, match="allow-prod-destroy"):
        manage.require_destroy_confirmation(prod, True, None, False)
    with pytest.raises(manage.LifecycleError, match="requires --yes"):
        manage.require_destroy_confirmation(prod, False, "PROD", True)
    manage.require_destroy_confirmation(prod, True, None, True)


def test_destroy_sql_is_idempotent_and_never_drops_protected_resources() -> None:
    suspend_sql = (
        ROOT / "sql" / "05_lifecycle" / "suspend_pipeline_tasks.sql"
    ).read_text(encoding="utf-8")
    suspended = re.findall(
        r"ALTER TASK IF EXISTS SKYPOINTS_DB\.RAW\.(TASK_\w+) SUSPEND;",
        suspend_sql,
    )
    assert suspended == list(manage.TASKS_IN_SUSPEND_ORDER)

    destroy_task_order = []
    all_destroy_sql = ""
    for _, relative in manage.DESTROY_SQL_SEQUENCE[1:]:
        sql = (ROOT / relative).read_text(encoding="utf-8")
        all_destroy_sql += sql.upper()
        destroy_task_order.extend(
            re.findall(
                r"DROP TASK IF EXISTS SKYPOINTS_DB\.RAW\.(TASK_\w+);",
                sql,
            )
        )
        for statement in re.findall(r"(?im)^\s*DROP\s+[^;]+;", sql):
            assert re.search(r"\bIF\s+EXISTS\b", statement, re.IGNORECASE)

    assert destroy_task_order == list(manage.TASKS_IN_SUSPEND_ORDER)
    assert "DROP DATABASE" not in all_destroy_sql
    assert not re.search(r"DROP SCHEMA IF EXISTS SKYPOINTS_DB\.AUDIT", all_destroy_sql)
    assert "DROP STORAGE INTEGRATION" not in all_destroy_sql
    assert "DROP WAREHOUSE" not in all_destroy_sql


def test_dcm_and_standalone_deployment_steps_remain_separate() -> None:
    assert all(
        "sql/" in script
        for _, script in manage.DEPLOY_SQL_SEQUENCE
    )
    assert not any(
        "bootstrap_dcm.sql" in script
        or "create_s3_storage_integration.sql" in script
        for _, script in manage.DEPLOY_SQL_SEQUENCE
    )
    assert manage.DESTROY_SQL_SEQUENCE[-1][1] == "sql/05_lifecycle/destroy_pipes.sql"
    assert manage.RESOURCE_GROUPS[-1][0].startswith("DCM-managed")
    assert "SKYPOINTS_DB database" in manage.PROTECTED_RESOURCES
    assert "SKYPOINTS_S3_STORAGE_INT storage integration" in manage.PROTECTED_RESOURCES
