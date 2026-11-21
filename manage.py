"""Safe lifecycle commands for the SkyPoints Snowflake project."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Sequence

import yaml


ROOT = Path(__file__).resolve().parent
MANIFEST_PATH = ROOT / "manifest.yml"
CONFIG_DIR = ROOT / "config"
SNOW = shutil.which("snow") or "snow"

TASKS_IN_SUSPEND_ORDER = (
    "TASK_COUNTRY_RECONCILIATION",
    "TASK_COUNTRY_ROUTING",
    "TASK_REDEMPTION_PROCESSING",
    "TASK_MEMBER_PROCESSING",
    "TASK_DQ_VALIDATION",
    "TASK_PARSE_AND_NORMALIZE",
    "TASK_INGESTION_VALIDATION",
    "TASK_REDEMPTION_INGESTION",
    "TASK_MEMBER_INGESTION",
)

DEPLOY_SQL_SEQUENCE = (
    ("Member auto-ingest pipe", "sql/01_ingestion/pipes/create_member_profile_pipe.sql"),
    ("Redemption auto-ingest pipe", "sql/01_ingestion/pipes/create_redemption_pipe.sql"),
    ("Phase 3 ingestion graph", "sql/02_orchestration_ingestion/deploy_ingestion_task_graph.sql"),
    (
        "Phase 4-5 DQ and business processing",
        "sql/03_processing/dq_and_transformation/deploy_ingestion_dq_and_business_transformation.sql",
    ),
    ("Phase 6A country routing", "sql/03_processing/country_routing/deploy_country_routing.sql"),
    (
        "Phase 6B-6C reconciliation",
        "sql/03_processing/country_movement_reconciliation/deploy_country_movement_reconciliation.sql",
    ),
    ("Phase 7 unified orchestration", "sql/04_unified_pipeline/deploy_unified_pipeline.sql"),
    ("Suspend all pipeline tasks", "sql/05_lifecycle/suspend_pipeline_tasks.sql"),
)

DESTROY_SQL_SEQUENCE = (
    ("Suspend pipeline tasks", "sql/05_lifecycle/suspend_pipeline_tasks.sql"),
    ("Remove Phase 7 control objects", "sql/05_lifecycle/destroy_phase7.sql"),
    (
        "Remove Phase 6B-6C reconciliation objects",
        "sql/05_lifecycle/destroy_phase6_reconciliation.sql",
    ),
    ("Remove Phase 6A routing objects", "sql/05_lifecycle/destroy_phase6_routing.sql"),
    ("Remove Phase 4-5 processing objects", "sql/05_lifecycle/destroy_phase45.sql"),
    ("Remove Phase 3 ingestion objects", "sql/05_lifecycle/destroy_phase3.sql"),
    ("Remove ingestion pipes", "sql/05_lifecycle/destroy_pipes.sql"),
)

COUNTRY_CODES = (
    "USA", "IND", "GBR", "CAN", "AUS", "DEU", "FRA", "JPN", "SGP", "NZL",
    "ZAF", "BRA", "MEX", "ARE", "SAU", "KOR", "ITA", "ESP", "NLD", "CHE",
)

RESOURCE_GROUPS = (
    (
        "Phase 7 standalone SQL",
        (
            "SKYPOINTS_DB.AUDIT.SP_RUN_COMPLETE_PIPELINE()",
            "SKYPOINTS_DB.AUDIT.SP_SUSPEND_PIPELINE_DESCENDANTS()",
            "SKYPOINTS_DB.AUDIT.PIPELINE_RUN_AUDIT",
            "SKYPOINTS_DB.AUDIT.PIPELINE_RUN_CONTROL",
        ),
    ),
    (
        "Phase 6B-6C standalone SQL",
        (
            "SKYPOINTS_DB.AUDIT.SP_VALIDATE_COUNTRY_ROUTING()",
            "SKYPOINTS_DB.AUDIT.COUNTRY_RECONCILIATION_AUDIT",
            "SKYPOINTS_DB.RAW.TASK_COUNTRY_RECONCILIATION",
        ),
    ),
    (
        "Phase 6A standalone SQL",
        (
            "SKYPOINTS_DB.CORE.SP_ROUTE_MEMBERS_BY_COUNTRY()",
            "SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_CONFIG",
            "SKYPOINTS_DB.AUDIT.COUNTRY_ROUTING_AUDIT",
            "SKYPOINTS_DB.AUDIT.COUNTRY_MOVEMENT_AUDIT",
            "SKYPOINTS_DB.RAW.TASK_COUNTRY_ROUTING",
            *(f"SKYPOINTS_DB.CORE.MEMBER_{code}" for code in COUNTRY_CODES),
        ),
    ),
    (
        "Phase 4-5 standalone SQL",
        (
            "SKYPOINTS_DB.STAGING.SP_PARSE_AND_NORMALIZE()",
            "SKYPOINTS_DB.STAGING.SP_RUN_DQ_VALIDATION()",
            "SKYPOINTS_DB.CORE.SP_PROCESS_MEMBERS()",
            "SKYPOINTS_DB.CORE.SP_PROCESS_REDEMPTIONS()",
            "SKYPOINTS_DB.RAW.TASK_PARSE_AND_NORMALIZE",
            "SKYPOINTS_DB.RAW.TASK_DQ_VALIDATION",
            "SKYPOINTS_DB.RAW.TASK_MEMBER_PROCESSING",
            "SKYPOINTS_DB.RAW.TASK_REDEMPTION_PROCESSING",
            "SKYPOINTS_DB.AUDIT.PHASE45_AUDIT",
            "SKYPOINTS_DB.AUDIT.ETL_FILE_STAGE_STATUS",
            "SKYPOINTS_DB.AUDIT.DQ_RULE_MASTER",
            "SKYPOINTS_DB.AUDIT.DQ_EXECUTION",
            "SKYPOINTS_DB.AUDIT.DQ_RULE_RESULT",
            "SKYPOINTS_DB.STAGING.MEMBER_PROFILE_PARSED",
            "SKYPOINTS_DB.STAGING.REDEMPTION_PARSED",
            "SKYPOINTS_DB.STAGING.DQ_QUARANTINE",
            "SKYPOINTS_DB.CORE.MEMBER_CURRENT",
            "SKYPOINTS_DB.CORE.MEMBER_HISTORY",
            "SKYPOINTS_DB.CORE.REDEMPTION_FACT",
        ),
    ),
    (
        "Phase 3 standalone SQL",
        (
            "SKYPOINTS_DB.RAW.SP_RUN_MEMBER_INGESTION()",
            "SKYPOINTS_DB.RAW.SP_RUN_REDEMPTION_INGESTION()",
            "SKYPOINTS_DB.RAW.SP_RUN_INGESTION_VALIDATION()",
            "SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION",
            "SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION",
            "SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION",
            "SKYPOINTS_DB.AUDIT.INGESTION_AUDIT",
        ),
    ),
    (
        "Standalone ingestion pipes",
        (
            "SKYPOINTS_DB.RAW.MEMBER_PROFILE_PIPE",
            "SKYPOINTS_DB.RAW.REDEMPTION_PIPE",
        ),
    ),
    (
        "DCM-managed resources (DCM CLI teardown)",
        (
            "SKYPOINTS_DB.RAW",
            "SKYPOINTS_DB.STAGING",
            "SKYPOINTS_DB.CORE",
            "SKYPOINTS_DB.ANALYTICS",
            "SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW",
            "SKYPOINTS_DB.RAW.REDEMPTION_RAW",
            "SKYPOINTS_DB.RAW.MEMBER_PROFILE_CSV",
            "SKYPOINTS_DB.RAW.REDEMPTION_JSON",
            "SKYPOINTS_DB.RAW.MEMBER_S3_STAGE",
            "SKYPOINTS_DB.RAW.REDEMPTION_S3_STAGE",
            "SKYPOINTS_ETL_WH (per DEV destroy policy)",
            "SKYPOINTS_DB.AUDIT.SKYPOINTS_DCM_PROJECT_DEV (project registration)",
        ),
    ),
)

PROTECTED_RESOURCES = (
    "SKYPOINTS_DB database",
    "SKYPOINTS_DB.AUDIT parent schema",
    "SKYPOINTS_S3_STORAGE_INT storage integration",
    "S3 bucket and uploaded objects",
    "AWS IAM roles, policies, and bucket notifications",
)

NO_CHANGE_MARKERS = (
    "no changes",
    "no change detected",
    "nothing to deploy",
    "already up to date",
)
PLACEHOLDER_PATTERN = re.compile(
    r"<[^>]*>|^(?:configure|placeholder|todo|tbd)(?:\b.*)?$",
    re.IGNORECASE,
)
ANSI_PATTERN = re.compile(r"\x1b\[[0-9;]*m")


class LifecycleError(RuntimeError):
    """A validation, CLI, or deployment step failed."""


@dataclass(frozen=True)
class TargetConfig:
    name: str
    manifest_target: str
    connection_name: str
    database: str
    warehouse: str
    storage_integration: str
    s3_bucket: str
    member_prefix: str
    redemption_prefix: str
    project_name: str
    project_owner: str
    delete_warehouse: bool


def _read_yaml(path: Path) -> dict:
    try:
        loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise LifecycleError(f"Required configuration file is missing: {path}") from exc
    except yaml.YAMLError as exc:
        raise LifecycleError(f"Invalid YAML in {path}: {exc}") from exc
    if not isinstance(loaded, dict):
        raise LifecycleError(f"Expected a YAML mapping in {path}")
    return loaded


def _is_placeholder(value: object) -> bool:
    if value is None:
        return True
    if isinstance(value, str):
        stripped = value.strip()
        return not stripped or bool(PLACEHOLDER_PATTERN.search(stripped))
    return False


def load_target_config(target: str, root: Path = ROOT) -> TargetConfig:
    normalized = target.strip().lower()
    if normalized not in {"dev", "staging", "prod"}:
        raise LifecycleError(
            f"Unknown target '{target}'. Choose one of: dev, staging, prod."
        )

    manifest = _read_yaml(root / "manifest.yml")
    manifest_targets = manifest.get("targets", {})
    if not isinstance(manifest_targets, dict):
        raise LifecycleError("manifest.yml must define a targets mapping.")
    manifest_target = normalized.upper()
    target_definition = manifest_targets.get(manifest_target)
    config_path = root / "config" / f"{normalized}.yml"
    config = _read_yaml(config_path)
    snowflake = config.get("snowflake", {})
    storage = config.get("storage", {})
    destroy_policy = config.get("destroy_policy", {})
    if not all(isinstance(item, dict) for item in (snowflake, storage, destroy_policy)):
        raise LifecycleError(
            f"{config_path} must define snowflake, storage, and destroy_policy mappings."
        )

    if target_definition is None:
        placeholders = []
        for section_name, section in (("snowflake", snowflake), ("storage", storage)):
            for key, value in section.items():
                if _is_placeholder(value):
                    placeholders.append(f"{section_name}.{key}")
        details = (
            f" Placeholder settings: {', '.join(placeholders)}."
            if placeholders
            else ""
        )
        available = ", ".join(sorted(str(key).lower() for key in manifest_targets))
        raise LifecycleError(
            f"Target '{normalized}' has no matching target in manifest.yml "
            f"(configured targets: {available or 'none'}).{details} "
            "Add a real manifest target and complete config before using it."
        )
    if not isinstance(target_definition, dict):
        raise LifecycleError(
            f"Target '{manifest_target}' in manifest.yml must be a mapping."
        )

    required = {
        "environment": config.get("environment"),
        "snowflake.connection_name": snowflake.get("connection_name"),
        "snowflake.database": snowflake.get("database"),
        "snowflake.warehouse": snowflake.get("warehouse"),
        "storage.integration": storage.get("integration"),
        "storage.s3_bucket": storage.get("s3_bucket"),
        "storage.member_prefix": storage.get("member_prefix"),
        "storage.redemption_prefix": storage.get("redemption_prefix"),
    }
    missing = [key for key, value in required.items() if _is_placeholder(value)]
    if config.get("environment") != normalized:
        missing.append(f"environment (expected '{normalized}')")
    if not isinstance(destroy_policy.get("delete_warehouse"), bool):
        missing.append("destroy_policy.delete_warehouse (must be true or false)")
    if missing:
        raise LifecycleError(
            f"Target '{normalized}' is not fully configured in {config_path}: "
            f"{', '.join(missing)}. Refusing to contact Snowflake."
        )

    project_name = target_definition.get("project_name")
    project_owner = target_definition.get("project_owner")
    account_identifier = target_definition.get("account_identifier")
    manifest_missing = [
        key
        for key, value in (
            ("account_identifier", account_identifier),
            ("project_name", project_name),
            ("project_owner", project_owner),
        )
        if _is_placeholder(value)
    ]
    if manifest_missing:
        raise LifecycleError(
            f"Target '{normalized}' has incomplete manifest settings: "
            f"{', '.join(manifest_missing)}."
        )

    if snowflake["database"] != str(project_name).split(".", 1)[0]:
        raise LifecycleError(
            f"config/{normalized}.yml database does not match the DCM project "
            f"database in manifest.yml."
        )
    for label, value in (
        ("database", snowflake["database"]),
        ("warehouse", snowflake["warehouse"]),
        ("storage.integration", storage["integration"]),
    ):
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", str(value)):
            raise LifecycleError(
                f"config/{normalized}.yml {label} must be a Snowflake identifier."
            )
    raw_definition = (
        root / "sources" / "definitions" / "02_raw_ingestion.sql"
    ).read_text(encoding="utf-8")
    integration_names = {
        match.upper()
        for match in re.findall(
            r"(?im)^\s*STORAGE_INTEGRATION\s*=\s*([A-Z0-9_]+)",
            raw_definition,
        )
    }
    if integration_names != {str(storage["integration"]).upper()}:
        raise LifecycleError(
            f"config/{normalized}.yml storage.integration does not match "
            "sources/definitions/02_raw_ingestion.sql."
        )
    storage_integration_sql = (
        root / "sql" / "00_setup" / "create_s3_storage_integration.sql"
    ).read_text(encoding="utf-8")
    created_integrations = {
        match.upper()
        for match in re.findall(
            r"(?im)^\s*CREATE\s+STORAGE\s+INTEGRATION\s+([A-Z0-9_]+)",
            storage_integration_sql,
        )
    }
    if created_integrations != {str(storage["integration"]).upper()}:
        raise LifecycleError(
            f"config/{normalized}.yml storage.integration does not match "
            "sql/00_setup/create_s3_storage_integration.sql."
        )
    configured_urls = {
        (bucket, prefix.rstrip("/") + "/")
        for bucket, prefix in re.findall(
            r"(?im)^\s*URL\s*=\s*'s3://([^/]+)/([^']+)'",
            raw_definition,
        )
    }
    expected_urls = {
        (str(storage["s3_bucket"]), str(storage["member_prefix"])),
        (str(storage["s3_bucket"]), str(storage["redemption_prefix"])),
    }
    if configured_urls != expected_urls:
        raise LifecycleError(
            f"config/{normalized}.yml bucket/prefix settings do not match "
            "the DCM external-stage URLs."
        )

    return TargetConfig(
        name=normalized,
        manifest_target=manifest_target,
        connection_name=str(snowflake["connection_name"]).strip(),
        database=str(snowflake["database"]).strip(),
        warehouse=str(snowflake["warehouse"]).strip(),
        storage_integration=str(storage["integration"]).strip(),
        s3_bucket=str(storage["s3_bucket"]).strip(),
        member_prefix=str(storage["member_prefix"]).strip(),
        redemption_prefix=str(storage["redemption_prefix"]).strip(),
        project_name=str(project_name).strip(),
        project_owner=str(project_owner).strip(),
        delete_warehouse=destroy_policy["delete_warehouse"],
    )


def require_destroy_confirmation(
    target: TargetConfig,
    yes: bool,
    typed_target: str | None,
    allow_prod_destroy: bool,
    input_fn: Callable[[str], str] = input,
) -> None:
    if target.name == "prod":
        if not allow_prod_destroy:
            raise LifecycleError(
                "Production destruction additionally requires --allow-prod-destroy."
            )
        if not yes:
            raise LifecycleError(
                "Production destruction requires --yes and --allow-prod-destroy."
            )
    if yes:
        return
    expected = target.manifest_target
    if typed_target is not None and typed_target.strip().upper() == expected:
        return
    answer = input_fn(
        f"Type {expected} to confirm destruction of target {target.name}: "
    )
    if answer.strip().upper() != expected:
        raise LifecycleError("Destruction confirmation did not match the target.")


class LifecycleManager:
    def __init__(
        self,
        target: TargetConfig,
        runner: Callable = subprocess.run,
        output: Callable[[str], None] = print,
        input_fn: Callable[[str], str] = input,
        executable: str = SNOW,
        root: Path = ROOT,
    ) -> None:
        self.target = target
        self.runner = runner
        self.output = output
        self.input_fn = input_fn
        self.executable = executable
        self.root = root
        self.completed: list[str] = []
        self.skipped: list[str] = []
        self._global_help = ""
        self._dcm_help = ""
        self._sql_help = ""

    def _invoke(
        self,
        args: Sequence[str],
        label: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess:
        command = [self.executable, *args]
        self.output(f"==> {label}: {' '.join(command)}")
        try:
            result = self.runner(
                command,
                cwd=self.root,
                text=True,
                capture_output=True,
                check=False,
            )
        except FileNotFoundError as exc:
            raise LifecycleError(
                "Snowflake CLI executable 'snow' was not found. Install/configure "
                "Snowflake CLI before running lifecycle commands."
            ) from exc
        except OSError as exc:
            raise LifecycleError(f"Could not run Snowflake CLI: {exc}") from exc
        stdout = result.stdout or ""
        stderr = result.stderr or ""
        self._last_stdout = stdout
        self._last_stderr = stderr
        if stdout:
            self.output(stdout.rstrip())
        if stderr:
            self.output(stderr.rstrip())
        if check and result.returncode != 0:
            details = (stderr or stdout or f"exit code {result.returncode}").strip()
            raise LifecycleError(f"{label} failed: {details}")
        return result

    @staticmethod
    def _has_option(help_text: str, option: str) -> bool:
        cleaned = ANSI_PATTERN.sub("", help_text)
        return re.search(
            rf"(?<![\w-]){re.escape(option)}(?:[\s,=]|$)",
            cleaned,
        ) is not None

    def _probe_cli(self, require_dcm: bool) -> None:
        version_result = self._invoke(
            ["--version"],
            "Check Snowflake CLI version",
        )
        version_text = (version_result.stdout or "") + (version_result.stderr or "")
        version_match = re.search(r"\b(\d+)\.(\d+)\.(\d+)\b", version_text)
        if require_dcm and not version_match:
            raise LifecycleError(
                "Could not determine Snowflake CLI version from `snow --version`."
            )
        if (
            require_dcm
            and version_match
            and tuple(int(part) for part in version_match.groups()) < (3, 24, 0)
        ):
            raise LifecycleError(
                "Snowflake CLI 3.24.0 or later is required for DCM lifecycle commands."
            )
        global_help = self._invoke(["--help"], "Inspect Snowflake CLI help")
        sql_help = self._invoke(["sql", "--help"], "Inspect snow sql help")
        if not all(
            self._has_option(sql_help.stdout or "", option)
            or self._has_option(global_help.stdout or "", option)
            for option in ("--connection", "--filename")
        ):
            raise LifecycleError(
                "Installed Snowflake CLI help does not document the required "
                "snow sql --connection/--filename options."
            )
        self._global_help = global_help.stdout or ""
        self._sql_help = sql_help.stdout or ""
        if require_dcm:
            dcm_help = self._invoke(["dcm", "--help"], "Inspect snow dcm help")
            self._dcm_help = (dcm_help.stdout or "") + "\n" + (
                dcm_help.stderr or ""
            )

    def _dcm_args(self, command: str) -> list[str]:
        help_result = self._invoke(
            ["dcm", command, "--help"],
            f"Inspect snow dcm {command} help",
        )
        help_text = (help_result.stdout or "") + self._dcm_help + self._global_help
        required_options = ("--target", "--connection")
        if command in {"create", "plan", "deploy"}:
            required_options += ("--from",)
        unsupported = [
            option for option in required_options
            if not self._has_option(help_text, option)
        ]
        if unsupported:
            raise LifecycleError(
                f"Installed snow dcm {command} help does not document required "
                f"options: {', '.join(unsupported)}. No command was run."
            )
        args = ["dcm", command]
        if self._has_option(help_text, "--from"):
            args.extend(["--from", "."])
        args.extend(["--target", self.target.manifest_target])
        args.extend(["--connection", self.target.connection_name])
        return args

    def _sql(
        self,
        script: str,
        label: str,
        skip_if_already_exists: bool = False,
    ) -> None:
        path = self.root / script
        if not path.is_file():
            raise LifecycleError(f"Required SQL script is missing: {script}")
        result = self._invoke(
            [
                "sql",
                "--connection",
                self.target.connection_name,
                "--filename",
                script,
            ],
            label,
            check=not skip_if_already_exists,
        )
        if (
            skip_if_already_exists
            and result.returncode != 0
            and self._already_exists(
                (result.stdout or "") + (result.stderr or "")
            )
        ):
            self.skipped.append(
                f"{label} (already exists; existing pipe was not replaced)"
            )
            return
        if result.returncode != 0:
            details = (
                result.stderr or result.stdout or f"exit code {result.returncode}"
            ).strip()
            raise LifecycleError(f"{label} failed: {details}")
        self.completed.append(label)

    def _role_preflight(self) -> None:
        role = self.target.project_owner
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", role):
            raise LifecycleError(
                "The manifest project owner cannot be safely used for role preflight."
            )
        sql = (
            f"DESC DATABASE {self.target.database};\n"
            f"DESC SCHEMA {self.target.database}.AUDIT;\n"
            f"DESC INTEGRATION {self.target.storage_integration};\n"
            "EXECUTE IMMEDIATE $$\n"
            "DECLARE\n"
            "    e_wrong_role EXCEPTION (-20091, "
            f"'Lifecycle operation requires active role {role}');\n"
            "BEGIN\n"
            f"    IF (CURRENT_ROLE() <> '{role}') THEN\n"
            "        RAISE e_wrong_role;\n"
            "    END IF;\n"
            "END;\n"
            "$$;\n"
        )
        with tempfile.TemporaryDirectory(prefix="skypoints-lifecycle-") as temp_dir:
            path = Path(temp_dir) / "check_active_role.sql"
            path.write_text(sql, encoding="utf-8")
            self._invoke(
                [
                    "sql",
                    "--connection",
                    self.target.connection_name,
                    "--filename",
                    str(path),
                ],
                f"Validate database, integration, and active role {role}",
            )

    @staticmethod
    def _already_exists(output: str) -> bool:
        lowered = output.lower()
        return "already exists" in lowered or "already created" in lowered

    @staticmethod
    def _plan_has_no_changes(output: str) -> bool:
        lowered = output.lower()
        return any(marker in lowered for marker in NO_CHANGE_MARKERS)

    def _print_summary(self, heading: str) -> None:
        self.output(f"\n{heading}")
        self.output("Completed:")
        for item in self.completed:
            self.output(f"  - {item}")
        if not self.completed:
            self.output("  - none")
        self.output("Skipped or left unchanged:")
        for item in self.skipped:
            self.output(f"  - {item}")
        if not self.skipped:
            self.output("  - none")

    def deploy(self) -> None:
        try:
            self._probe_cli(require_dcm=True)
            self._role_preflight()

            create_args = self._dcm_args("create")
            create_result = self._invoke(
                create_args,
                "Create/verify DCM project",
                check=False,
            )
            create_output = (create_result.stdout or "") + (create_result.stderr or "")
            if create_result.returncode == 0:
                self.completed.append("Create/verify DCM project")
            elif self._already_exists(create_output):
                self.skipped.append("DCM project already exists")
            else:
                raise LifecycleError(
                    "Create DCM project failed: "
                    + (create_output.strip() or f"exit code {create_result.returncode}")
                )

            plan_result = self._invoke(self._dcm_args("plan"), "Plan DCM deployment")
            plan_text = (plan_result.stdout or "") + (plan_result.stderr or "")
            self.completed.append("Plan DCM deployment")
            if self._plan_has_no_changes(plan_text):
                self.skipped.append("DCM deploy (plan reports no changes)")
            else:
                self._invoke(self._dcm_args("deploy"), "Deploy DCM-managed resources")
                self.completed.append("Deploy DCM-managed resources")

            for label, script in DEPLOY_SQL_SEQUENCE:
                self._sql(
                    script,
                    label,
                    skip_if_already_exists=script.startswith(
                        "sql/01_ingestion/pipes/"
                    ),
                )
            self._print_summary("Deployment summary")
        except LifecycleError:
            self._print_summary("Deployment stopped; completed steps are listed above")
            raise

    def run_pipeline(self) -> None:
        self._probe_cli(require_dcm=False)
        self._sql(
            "sql/04_unified_pipeline/execute_unified_pipeline.sql",
            "Run unified Phase 3-6C pipeline",
        )

    def monitor(self) -> None:
        self._probe_cli(require_dcm=False)
        self._sql(
            "sql/04_unified_pipeline/monitor_unified_pipeline.sql",
            "Monitor unified Phase 3-6C pipeline",
        )

    def _dcm_destroy_command(self) -> tuple[list[str], list[str]]:
        available = set()
        for line in ANSI_PATTERN.sub("", self._dcm_help).splitlines():
            match = re.match(r"^\s{2,}([a-z][a-z-]+)\s{2,}", line)
            if match:
                available.add(match.group(1))
        missing_commands = {"purge", "drop"} - available
        if missing_commands:
            raise LifecycleError(
                "The installed snow dcm --help must advertise both `purge` and "
                f"`drop`; missing: {', '.join(sorted(missing_commands))}. "
                "No project resources were deleted."
            )

        if not self.root.is_dir():
            raise LifecycleError(
                f"DCM project directory does not exist: {self.root}. "
                "No project resources were deleted."
            )

        def command_help(command: str) -> str:
            help_result = self._invoke(
                ["dcm", command, "--help"],
                f"Inspect snow dcm {command} help",
                check=False,
            )
            if help_result.returncode != 0:
                details = (
                    help_result.stderr
                    or help_result.stdout
                    or f"exit code {help_result.returncode}"
                ).strip()
                raise LifecycleError(
                    f"Could not inspect installed snow dcm {command} help: {details}. "
                    "No project resources were deleted."
                )
            return (help_result.stdout or "") + "\n" + (
                help_result.stderr or ""
            )

        def command_args(
            command: str,
            help_text: str,
            confirmation_option: str | None = None,
        ) -> list[str]:
            required_options = ("--from", "--target", "--connection")
            unsupported = [
                option
                for option in required_options
                if not self._has_option(help_text, option)
            ]
            if unsupported:
                raise LifecycleError(
                    f"Installed snow dcm {command} help does not document required "
                    f"options: {', '.join(unsupported)}. No project resources were "
                    "deleted."
                )
            if command == "purge" and confirmation_option is None:
                raise LifecycleError(
                    "Installed snow dcm purge help must document a non-interactive "
                    "`--force` or `--yes` confirmation option. No project resources "
                    "were deleted."
                )

            args = [
                "dcm",
                command,
                "--from",
                ".",
                "--target",
                self.target.manifest_target,
                "--connection",
                self.target.connection_name,
            ]
            if confirmation_option:
                args.append(confirmation_option)
            return args

        purge_help_text = command_help("purge")
        drop_help_text = command_help("drop")
        purge_confirmation = next(
            (
                option
                for option in ("--force", "--yes")
                if self._has_option(purge_help_text, option)
            ),
            None,
        )
        purge_args = command_args("purge", purge_help_text, purge_confirmation)
        drop_args = command_args("drop", drop_help_text)
        return purge_args, drop_args

    def _print_destroy_plan(self) -> None:
        self.output(f"Destroy plan for target {self.target.name} ({self.target.manifest_target})")
        for group, resources in RESOURCE_GROUPS:
            self.output(f"{group}:")
            for resource in resources:
                self.output(f"  - {resource}")
        self.output("Always protected:")
        for resource in PROTECTED_RESOURCES:
            self.output(f"  - {resource}")
        if not self.target.delete_warehouse:
            self.output(
                "Warehouse deletion is disabled by target policy; complete destroy "
                "is blocked before any resource is removed."
            )

    @staticmethod
    def _dcm_project_is_missing(output: str) -> bool:
        lowered = output.lower()
        return "project" in lowered and any(
            marker in lowered
            for marker in ("does not exist", "not found", "no such")
        )

    def destroy(
        self,
        yes: bool = False,
        typed_target: str | None = None,
        allow_prod_destroy: bool = False,
    ) -> None:
        self._print_destroy_plan()
        if not self.target.delete_warehouse:
            raise LifecycleError(
                "Target destroy policy does not permit deleting the DCM-managed warehouse."
            )
        require_destroy_confirmation(
            self.target,
            yes,
            typed_target,
            allow_prod_destroy,
            self.input_fn,
        )
        try:
            self._probe_cli(require_dcm=True)
            dcm_purge_args, dcm_drop_args = self._dcm_destroy_command()
            self._role_preflight()
            for label, script in DESTROY_SQL_SEQUENCE:
                self._sql(script, label)
            purge_result = self._invoke(
                dcm_purge_args,
                "Purge DCM-managed resources",
                check=False,
            )
            purge_output = (purge_result.stdout or "") + (
                purge_result.stderr or ""
            )
            if self._dcm_project_is_missing(purge_output):
                self.skipped.append(
                    "DCM project already absent; purge was not confirmed, and "
                    "DCM-managed entities may remain"
                )
                raise LifecycleError(
                    "The DCM project is already absent. Purge did not complete, so "
                    "existing DCM-managed entities were not confirmed removed; "
                    "complete destruction was not completed."
                )
            if purge_result.returncode != 0:
                details = (
                    purge_result.stderr
                    or purge_result.stdout
                    or f"exit code {purge_result.returncode}"
                ).strip()
                raise LifecycleError(
                    f"DCM purge failed; DCM drop was not run: {details}"
                )
            self.completed.append("DCM purge completed")

            drop_result = self._invoke(
                dcm_drop_args,
                "Drop DCM project",
                check=False,
            )
            if drop_result.returncode != 0:
                details = (
                    drop_result.stderr
                    or drop_result.stdout
                    or f"exit code {drop_result.returncode}"
                ).strip()
                raise LifecycleError(
                    "DCM purge completed, but DCM project drop failed. Managed "
                    "entities were purged, but the DCM project object remains; "
                    f"complete destruction was not completed. Details: {details}"
                )
            self.completed.append("DCM project dropped")
            self.completed.append("Complete destruction completed")
            self._print_summary("Destruction summary")
        except LifecycleError:
            self._print_summary(
                "Destruction stopped; some completed steps may have removed resources"
            )
            raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Deploy, run, monitor, or safely destroy the SkyPoints ETL project."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("deploy", "destroy", "run", "monitor"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument(
            "--target",
            required=True,
            choices=("dev", "staging", "prod"),
            help="Configured manifest/config target.",
        )
        if command == "destroy":
            subparser.add_argument(
                "--yes",
                action="store_true",
                help="Skip typing the target name; production also requires its safeguard.",
            )
            subparser.add_argument(
                "--confirm-target",
                help="Typed target name alternative to --yes.",
            )
            subparser.add_argument(
                "--allow-prod-destroy",
                action="store_true",
                help="Additional required safeguard for production destruction.",
            )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        target = load_target_config(args.target)
        manager = LifecycleManager(target)
        if args.command == "deploy":
            manager.deploy()
        elif args.command == "destroy":
            manager.destroy(
                yes=args.yes,
                typed_target=args.confirm_target,
                allow_prod_destroy=args.allow_prod_destroy,
            )
        elif args.command == "run":
            manager.run_pipeline()
        else:
            manager.monitor()
        return 0
    except LifecycleError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
