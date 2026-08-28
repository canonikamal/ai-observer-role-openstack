#!/usr/bin/env python3
"""Static checks for ai_observer policy overrides and generated ZIPs."""

from __future__ import annotations

import re
import sys
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OVERRIDES = ROOT / "overrides"
DIST = ROOT / "dist"
README = ROOT / "README.md"
BUILD_SCRIPT = ROOT / "scripts" / "build-policyd-override.sh"

EXPECTED_SERVICES = ("keystone", "nova", "neutron", "cinder", "glance", "octavia")
POLICY_LINE = re.compile(r'^\s*"([^"]+)"\s*:\s*"([^"]*)"\s*(?:#.*)?$')
WRITE_KEY_RE = re.compile(
    r"(^|:|-|_)("
    r"add|attach|cache|communitize|confirm|create|delete|failover|modify|"
    r"post|publicize|put|reboot|rebuild|remove|resize|revert|set|start|stop|"
    r"trigger|update|upload|write"
    r")($|:|-|_)",
    re.IGNORECASE,
)
READ_WORD_RE = re.compile(r"(^|:|-|_)(get|list|read|show|download|index)($|:|-|_)", re.IGNORECASE)
FORBIDDEN_EMPTY_VALUES = {"", "@"}
CINDER_PROJECT_MUTATIONS = (
    "volume:create",
    "volume:create_from_image",
    "volume:multiattach",
    "volume:update",
    "volume:delete",
    "volume:create_snapshot",
    "volume:update_snapshot",
    "volume:delete_snapshot",
    "volume:update_snapshot_metadata",
    "volume:delete_snapshot_metadata",
    "volume:create_volume_metadata",
    "volume:update_volume_metadata",
    "volume:delete_volume_metadata",
    "volume:update_readonly_flag",
    "volume:create_transfer",
    "volume:accept_transfer",
    "volume:delete_transfer",
    "volume_extension:volume_actions:attach",
    "volume_extension:volume_actions:detach",
    "volume_extension:volume_actions:reserve",
    "volume_extension:volume_actions:unreserve",
    "volume_extension:volume_actions:upload_image",
    "volume:attachment_create",
    "volume:attachment_update",
    "volume:attachment_delete",
    "volume:attachment_complete",
    "volume:multiattach_bootable_volume",
)
CINDER_ADMIN_READS = (
    "volume_extension:default_get",
    "volume_extension:default_get_all",
    "group:group_types_specs:get",
    "group:group_types_specs:get_all",
    "volume_extension:types_extra_specs:read_sensitive",
)
CINDER_HARD_ADMIN_READS = (
    "volume_extension:services:index",
    "scheduler_extension:scheduler_stats:get_pools",
    "volume_extension:capabilities",
    "volume_extension:qos_specs_manage:get",
    "volume_extension:qos_specs_manage:get_all",
)
CINDER_FILTERED_READS = (
    "group:access_group_types_specs",
)


class CheckResult:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


def parse_policy(path: Path, result: CheckResult) -> dict[str, str]:
    policy: dict[str, str] = {}
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = POLICY_LINE.match(line)
        if not match:
            result.error(f"{path}:{lineno}: unsupported policy line format")
            continue
        key, value = match.groups()
        if key in policy:
            result.error(f"{path}:{lineno}: duplicate policy key {key!r}")
        policy[key] = value
    return policy


def value_mentions_ai(value: str) -> bool:
    return re.search(r"(^|[^A-Za-z0-9_-])role:ai_observer([^A-Za-z0-9_-]|$)", value) is not None


def is_write_policy_key(key: str) -> bool:
    if READ_WORD_RE.search(key) and not WRITE_KEY_RE.search(key):
        return False
    return WRITE_KEY_RE.search(key) is not None


def check_policy_file(service: str, path: Path, result: CheckResult) -> None:
    policy = parse_policy(path, result)

    for key, value in policy.items():
        if value in FORBIDDEN_EMPTY_VALUES:
            result.error(f"{path}: {key!r} has dangerous open policy value {value!r}")

        if key == "default" and value != "role:admin":
            result.error(f"{path}: default policy must remain role:admin")

        if is_write_policy_key(key) and value_mentions_ai(value):
            result.error(f"{path}: write-like policy {key!r} grants ai_observer: {value!r}")

    if service == "nova":
        required = {
            "project_member_api": "role:member",
            "os_compute_api:servers:create": "rule:project_member_api",
            "os_compute_api:servers:delete": "rule:project_member_api",
        }
        for key, needle in required.items():
            if needle not in policy.get(key, ""):
                result.error(f"{path}: {key!r} must require {needle!r}")

    if service == "neutron":
        owner = policy.get("owner", "")
        if "role:member" not in owner or "project_id:%(project_id)s" not in owner:
            result.error(f"{path}: Neutron owner rule must require role:member and project scope")

    if service == "cinder":
        if value_mentions_ai(policy.get("volume_extension:hosts", "")):
            result.error(
                f"{path}: Cinder 'volume_extension:hosts' covers both GET and PUT "
                "and must not grant ai_observer"
            )

        for alias in ("admin_or_owner", "xena_system_admin_or_project_member"):
            value = policy.get(alias, "")
            if "role:member" not in value or "project_id:%(project_id)s" not in value:
                result.error(
                    f"{path}: Cinder alias {alias!r} must require member and project scope"
                )
            if value_mentions_ai(value):
                result.error(f"{path}: Cinder alias {alias!r} must not include ai_observer")

        for key in CINDER_PROJECT_MUTATIONS:
            value = policy.get(key, "")
            if value != "rule:xena_system_admin_or_project_member":
                result.error(
                    f"{path}: Cinder mutation policy {key!r} must explicitly use "
                    "'rule:xena_system_admin_or_project_member'"
                )

        for key in CINDER_ADMIN_READS:
            value = policy.get(key, "")
            if value != "role:admin or role:ai_observer":
                result.error(
                    f"{path}: Cinder admin read policy {key!r} must preserve admin "
                    "and grant only ai_observer"
                )

        for key in CINDER_HARD_ADMIN_READS:
            if value_mentions_ai(policy.get(key, "")):
                result.error(
                    f"{path}: Cinder hard-admin read {key!r} must not grant "
                    "ai_observer because Caracal rejects it below policy authorization"
                )

        for key in CINDER_FILTERED_READS:
            if value_mentions_ai(policy.get(key, "")):
                result.error(
                    f"{path}: Cinder aggregate-field read {key!r} must not grant "
                    "ai_observer because Caracal still filters the sensitive field"
                )

    if service == "glance":
        for key in ("add_image", "modify_image", "delete_image", "upload_image"):
            value = policy.get(key, "")
            if "role:member" not in value or "role:ai_observer" in value:
                result.error(f"{path}: Glance write policy {key!r} must require member/admin only")


def check_layout(result: CheckResult) -> None:
    services = sorted(p.name for p in OVERRIDES.iterdir() if p.is_dir())
    expected = sorted(EXPECTED_SERVICES)
    if services != expected:
        result.error(f"override directories {services!r} do not match expected {expected!r}")

    if (OVERRIDES / "placement").exists():
        result.error("overrides/placement must not exist; Placement is not packaged in this override set")

    if (DIST / "placement-policyd-override.zip").exists():
        result.error("dist/placement-policyd-override.zip must not exist")

    build_text = BUILD_SCRIPT.read_text(encoding="utf-8")
    if "placement" in build_text:
        result.error("build script still references placement")

    if README.exists():
        readme = README.read_text(encoding="utf-8")
        if "placement-policyd-override.zip" in readme or "attach-resource placement" in readme:
            result.error("README still contains placement override attach/build instructions")
    else:
        result.warn("README.md not found; skipping README placement-reference check")


def check_zip(service: str, result: CheckResult) -> None:
    src = OVERRIDES / service / "ai-observer.yaml"
    archive = DIST / f"{service}-policyd-override.zip"
    if not archive.exists():
        result.error(f"missing generated archive {archive}")
        return

    try:
        with zipfile.ZipFile(archive) as zf:
            names = sorted(zf.namelist())
            if names != ["ai-observer.yaml"]:
                result.error(f"{archive}: expected only ai-observer.yaml, found {names!r}")
                return
            zipped = zf.read("ai-observer.yaml")
    except zipfile.BadZipFile:
        result.error(f"{archive}: bad zip file")
        return

    if zipped != src.read_bytes():
        result.error(f"{archive}: content does not match {src}; rebuild archives")


def main() -> int:
    result = CheckResult()

    check_layout(result)
    for service in EXPECTED_SERVICES:
        path = OVERRIDES / service / "ai-observer.yaml"
        if not path.exists():
            result.error(f"missing {path}")
            continue
        check_policy_file(service, path, result)
        check_zip(service, result)

    for warning in result.warnings:
        print(f"WARN: {warning}")
    for error in result.errors:
        print(f"ERROR: {error}")

    if result.errors:
        print(f"Static validation failed with {len(result.errors)} error(s).")
        return 1

    print("Static validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
