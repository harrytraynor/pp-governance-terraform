#!/usr/bin/env python3
"""Firm and advisory checks for tiers/ and lanes/.

Firm failures exit 1. Advisory findings are printed and do not fail the run.
The same firm rules that can be expressed in Terraform are also preconditions
on the lanes stack, so a local plan still fails closed if this script is skipped.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML is required. Install it with: python3 -m pip install pyyaml\n")
    sys.exit(1)

from lane_states import SHARED, SLUG_RE, slug, state_key

ROOT = Path(__file__).resolve().parents[1]
SHARE_MODES = {"no limit", "exclude sharing with security groups"}
CHECKER_MODES = {"none", "warn", "block"}
BACKUP_DAYS = {7, 14, 21, 28}
DATA_GROUPS = {"Business", "NonBusiness", "Blocked", "Ignore"}
DEV_MODES = {"per-solution", "per-cost-centre", "per-builder"}
TIER_NAMES = {"sandbox", "small", "medium", "large", "exception"}
GUID = r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
LANE_KEYS = {
    "lane",
    "cost_centre",
    "tier",
    "owner",
    "dev_mode",
    "outside_group",
    "exception_expires_on",
    "triggers",
    "member_object_ids",
}

# Optional lane keys. A lane that omits them gets a Sandbox dev environment.
DEV_ENVIRONMENT_TYPES = {"Sandbox", "Developer"}

GUID_RE = re.compile(GUID)


def load_yaml_dir(directory: Path, recursive: bool = False) -> list[tuple[str, dict]]:
    docs = []
    if not directory.is_dir():
        return docs
    paths = directory.rglob("*.yaml") if recursive else directory.glob("*.yaml")
    for path in sorted(paths):
        relative = path.relative_to(directory).as_posix()
        if any(part.startswith(".") for part in path.relative_to(directory).parts):
            continue
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise SystemExit(f"{directory.name}/{relative}: expected a YAML mapping")
        docs.append((relative, data))
    return docs


def environment_display_name(cost_centre: str, lane: str, stage: str) -> str:
    return f"{slug(cost_centre)}-{slug(lane)}-{stage}"


def display_name_errors(docs: list[tuple[str, dict]], tiers: dict[str, dict]) -> list[str]:
    """Fail when two environments would share a name now that the tier is omitted."""
    owners: dict[str, str] = {}
    errors: list[str] = []
    fan_in: dict[str, str] = {}

    def claim(name: str, source: str) -> None:
        previous = owners.get(name)
        if previous is not None:
            errors.append(
                f"{source}: display name {name} collides with {previous}. "
                "Names are <cost centre>-<lane>-<stage> and must stay unique per lane and stage."
            )
        else:
            owners[name] = source

    for filename, lane in docs:
        if not isinstance(lane, dict):
            continue
        lane_name = lane.get("lane")
        cost_centre = lane.get("cost_centre")
        if not isinstance(lane_name, str) or not lane_name or not isinstance(cost_centre, str):
            continue
        source = f"lanes/{filename}"
        if slug(cost_centre) == "" or slug(lane_name) == "":
            errors.append(f"{source}: cost centre and lane must still contain a letter or digit after slugifying")
            continue
        claim(environment_display_name(cost_centre, lane_name, "dev"), source)
        tier_name = lane.get("tier")
        tier = tiers.get(tier_name) if isinstance(tier_name, str) else None
        if not isinstance(tier, dict) or lane.get("outside_group") is True:
            continue
        release = tier.get("release") or {}
        if release.get("dedicated_prod"):
            claim(environment_display_name(cost_centre, lane_name, "test"), f"{source} test")
            claim(environment_display_name(cost_centre, lane_name, "prod"), f"{source} prod")
        elif release.get("fan_in"):
            fan_in.setdefault(str(tier_name), source)

    for tier_name, source in fan_in.items():
        claim("shared-all-lanes-test", f"{source} (shared fan-in tier {tier_name})")
        claim("shared-all-lanes-prod", f"{source} (shared fan-in tier {tier_name})")
    return errors


def duplicate_lane_errors(docs: list[tuple[str, dict]]) -> list[str]:
    seen: dict[str, str] = {}
    errors: list[str] = []
    for filename, lane in docs:
        lane_name = lane.get("lane") if isinstance(lane, dict) else None
        if not isinstance(lane_name, str) or not lane_name:
            continue
        if lane_name in seen:
            errors.append(
                f"lanes/{filename}: duplicate lane name {lane_name} "
                f"(also lanes/{seen[lane_name]}). The Terraform key is the lane field, not the folder."
            )
        else:
            seen[lane_name] = filename
    return errors


def check_tier(name: str, tier: dict) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    label = f"tiers/{name}"

    def err(message: str) -> None:
        errors.append(f"{label}: {message}")

    tier_name = tier.get("tier")
    if tier_name not in TIER_NAMES:
        err(f"tier must be one of {', '.join(sorted(TIER_NAMES))}")
        return errors, warnings

    rules = tier.get("environment_group", {}).get("rules", {})
    sharing = rules.get("sharing_controls") or {}
    mode = sharing.get("share_mode")
    if mode not in SHARE_MODES:
        err("share_mode must be 'no limit' or 'exclude sharing with security groups'")
    elif mode == "no limit" and sharing.get("share_max_limit") not in (None,):
        err("share_max_limit must be empty when share_mode is 'no limit'")
    elif mode == "exclude sharing with security groups":
        limit = sharing.get("share_max_limit")
        if not isinstance(limit, int) or isinstance(limit, bool) or not 0 <= limit <= 99:
            err("share_max_limit must be an integer from 0 to 99")

    checker = rules.get("solution_checker_enforcement") or {}
    if checker.get("solution_checker_mode") not in CHECKER_MODES:
        err("solution_checker_mode must be none, warn, or block")

    backup = (rules.get("backup_retention") or {}).get("period_in_days")
    if backup not in BACKUP_DAYS:
        err("backup period_in_days must be 7, 14, 21, or 28")

    release = tier.get("release") or {}
    if release.get("fan_in") and release.get("dedicated_prod"):
        err("fan_in and dedicated_prod cannot both be true")

    data_group = (tier.get("dlp") or {}).get("custom_connectors_data_group")
    if data_group not in DATA_GROUPS:
        err("dlp.custom_connectors_data_group must be Business, NonBusiness, Blocked, or Ignore")

    connectors = (tier.get("dlp") or {}).get("business_connector_ids") or []
    if not isinstance(connectors, list) or not connectors:
        err("dlp.business_connector_ids must be a non-empty list")
    else:
        for connector in connectors:
            if not isinstance(connector, str) or not connector.startswith("/providers/Microsoft.PowerApps/apis/"):
                err(f"business connector id must be a full Power Apps id, got {connector!r}")

    policies = rules.get("advanced_connector_policies")
    if policies:
        allowed = policies.get("allowed_connectors") or []
        if not allowed:
            err("advanced_connector_policies.allowed_connectors is empty")
        for connector in allowed:
            if connector.get("actions_mode") not in {"all_allowed", "some_allowed"}:
                err("advanced connector actions_mode must be all_allowed or some_allowed")
            short_id = connector.get("connector_id", "")
            if short_id.startswith("/providers/"):
                err("advanced connector ids are short names, for example shared_commondataservice")

    managed = tier.get("ungrouped_managed_environment")
    if managed:
        mode = managed.get("limit_sharing_mode")
        if mode not in {"ExcludeSharingToSecurityGroups", "NoLimit"}:
            err("ungrouped limit_sharing_mode must be ExcludeSharingToSecurityGroups or NoLimit")
        checker_mode = managed.get("solution_checker_mode")
        if checker_mode not in {"None", "Warn", "Block"}:
            err("ungrouped solution_checker_mode must be None, Warn, or Block")

    if tier_name in {"large", "exception", "sandbox"} and tier.get("firm") is not True:
        warnings.append(f"{label}: this size is documented as firm, and firm is not true")

    return errors, warnings


def check_lane(name: str, lane: dict, tiers: dict[str, dict], today: dt.date) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    label = f"lanes/{name}"

    def err(message: str) -> None:
        errors.append(f"{label}: {message}")

    missing = LANE_KEYS.difference(lane)
    if missing:
        err(f"missing keys: {', '.join(sorted(missing))}")
        return errors, warnings

    if not isinstance(lane.get("lane"), str) or not lane["lane"]:
        err("lane must be a non-empty string")
    centre = str(lane.get("cost_centre", ""))
    centre_slug = slug(centre)
    # "shared" is the fan-in state key, so a lane must not slug to it.
    # Check that before the CC- shape so the reserved word is the error you see.
    if centre_slug == SHARED or (centre_slug != "" and not SLUG_RE.fullmatch(centre_slug)):
        err(f"cost_centre {centre!r} slugs to {centre_slug!r}, which cannot be a state key")
    elif not re.fullmatch(r"CC-[A-Za-z0-9-]+", centre):
        err("cost_centre must look like CC-0000")
    elif state_key(centre_slug) != f"lanes/{centre_slug}.tfstate":
        err("cost_centre state key must be lanes/<slug>.tfstate")
    owner = str(lane.get("owner", ""))
    if "@" not in owner or " " in owner:
        err("owner must be an email-style id with no spaces")
    if lane.get("dev_mode") not in DEV_MODES:
        err(f"dev_mode must be one of {', '.join(sorted(DEV_MODES))}")
    if not isinstance(lane.get("outside_group"), bool):
        err("outside_group must be true or false")
    members = lane.get("member_object_ids")
    if not isinstance(members, list):
        err("member_object_ids must be a list")
    else:
        for member in members:
            if not isinstance(member, str) or not GUID_RE.fullmatch(member):
                err(f"member_object_ids entry is not an object id: {member!r}")

    dev_type = lane.get("dev_environment_type") or "Sandbox"
    dev_owner = lane.get("dev_environment_owner_object_id")
    if dev_type not in DEV_ENVIRONMENT_TYPES:
        err(f"dev_environment_type must be one of {', '.join(sorted(DEV_ENVIRONMENT_TYPES))}")
    elif dev_type == "Developer":
        if not isinstance(dev_owner, str) or not GUID_RE.fullmatch(dev_owner):
            err("dev_environment_type Developer requires dev_environment_owner_object_id (an Entra user object id)")
    elif dev_owner is not None:
        err("dev_environment_owner_object_id is only valid when dev_environment_type is Developer")

    triggers = lane.get("triggers")
    if not isinstance(triggers, dict) or not isinstance(triggers.get("access"), bool) or not isinstance(triggers.get("complexity"), bool):
        err("triggers.access and triggers.complexity must be true or false")
        triggers = {"access": False, "complexity": False}

    tier_name = lane.get("tier")
    tier = tiers.get(tier_name)
    if tier is None:
        err(f"unknown tier {tier_name!r}")
        return errors, warnings

    expiry = lane.get("exception_expires_on")
    if tier_name == "exception":
        if not expiry:
            err("exception tier requires exception_expires_on (YYYY-MM-DD)")
        else:
            try:
                expires = dt.date.fromisoformat(str(expiry))
            except ValueError:
                err("exception_expires_on must be YYYY-MM-DD")
            else:
                if expires < today:
                    err(f"exception_expires_on {expires.isoformat()} is in the past")
    elif expiry:
        err("exception_expires_on is only valid when tier is exception")

    if lane.get("outside_group") and not tier.get("ungrouped_managed_environment"):
        err("outside_group requires ungrouped_managed_environment on the tier")

    if triggers.get("access") and tier_name in {"sandbox", "small"}:
        warnings.append(f"{label}: access trigger is true on tier {tier_name}. That usually means a larger size. Advisory only.")
    if triggers.get("complexity") and tier_name not in {"large", "exception"}:
        warnings.append(f"{label}: complexity trigger is true on tier {tier_name}. That usually means large or exception. Advisory only.")

    return errors, warnings


def check_repository(root: Path, today: dt.date | None = None) -> tuple[list[str], list[str]]:
    today = today or dt.date.today()
    errors: list[str] = []
    warnings: list[str] = []
    tiers: dict[str, dict] = {}
    for filename, tier in load_yaml_dir(root / "tiers"):
        found, notes = check_tier(filename, tier)
        errors.extend(found)
        warnings.extend(notes)
        tier_name = tier.get("tier")
        if isinstance(tier_name, str):
            if tier_name in tiers:
                errors.append(f"tiers/{filename}: duplicate tier name {tier_name}")
            tiers[tier_name] = tier

    lane_docs = load_yaml_dir(root / "lanes", recursive=True)
    for filename, lane in lane_docs:
        found, notes = check_lane(filename, lane, tiers, today)
        errors.extend(found)
        warnings.extend(notes)
    errors.extend(duplicate_lane_errors(lane_docs))
    errors.extend(display_name_errors(lane_docs, tiers))
    if not lane_docs:
        errors.append("lanes/: add at least one lane file")
    return errors, warnings


def self_test() -> None:
    today = dt.date(2026, 10, 21)
    tier = {
        "tier": "exception",
        "firm": True,
        "environment_group": {
            "rules": {
                "sharing_controls": {
                    "share_mode": "exclude sharing with security groups",
                    "share_max_limit": 5,
                },
                "solution_checker_enforcement": {"solution_checker_mode": "block"},
                "backup_retention": {"period_in_days": 28},
            }
        },
        "release": {"fan_in": False, "dedicated_prod": True},
        "dlp": {
            "business_connector_ids": ["/providers/Microsoft.PowerApps/apis/shared_commondataservice"],
            "custom_connectors_data_group": "Blocked",
        },
        "ungrouped_managed_environment": {
            "limit_sharing_mode": "ExcludeSharingToSecurityGroups",
            "solution_checker_mode": "Block",
        },
    }
    lane = {
        "lane": "archive",
        "cost_centre": "CC-0000",
        "tier": "exception",
        "owner": "owner@example.com",
        "dev_mode": "per-solution",
        "outside_group": False,
        "exception_expires_on": None,
        "triggers": {"access": False, "complexity": False},
        "member_object_ids": [],
    }
    errors, _ = check_lane("archive.yaml", lane, {"exception": tier}, today)
    if not any("exception_expires_on" in item for item in errors):
        raise SystemExit("self-test failed: a missing exception expiry was accepted")

    lane["exception_expires_on"] = "2026-10-01"
    errors, _ = check_lane("archive.yaml", lane, {"exception": tier}, today)
    if not any("in the past" in item for item in errors):
        raise SystemExit("self-test failed: a past exception expiry was accepted")

    lane["exception_expires_on"] = "2026-12-01"
    errors, warnings = check_lane("archive.yaml", lane, {"exception": tier}, today)
    if errors:
        raise SystemExit(f"self-test failed: a valid exception lane was rejected: {errors}")

    small = dict(lane)
    small["tier"] = "small"
    small["exception_expires_on"] = None
    small["triggers"] = {"access": True, "complexity": False}
    small_tier = dict(tier)
    small_tier["tier"] = "small"
    _, warnings = check_lane("small.yaml", small, {"small": small_tier}, today)
    if not warnings:
        raise SystemExit("self-test failed: an access trigger on small produced no warning")
    developer = dict(small)
    developer["triggers"] = {"access": False, "complexity": False}
    developer["dev_environment_type"] = "Developer"
    errors, _ = check_lane("developer.yaml", developer, {"small": small_tier}, today)
    if not any("dev_environment_owner_object_id" in item for item in errors):
        raise SystemExit("self-test failed: a Developer lane without an owner was accepted")
    developer["dev_environment_owner_object_id"] = "00000000-0000-0000-0000-000000000001"
    errors, _ = check_lane("developer.yaml", developer, {"small": small_tier}, today)
    if errors:
        raise SystemExit(f"self-test failed: a valid Developer lane was rejected: {errors}")
    shared_centre = dict(developer)
    shared_centre["cost_centre"] = "shared"
    errors, _ = check_lane("shared.yaml", shared_centre, {"small": small_tier}, today)
    if not any("state key" in item for item in errors):
        raise SystemExit(f"self-test failed: a cost centre that slugs to shared was accepted: {errors}")
    duplicates = duplicate_lane_errors([
        ("customer-service.yaml", {"lane": "customer-service"}),
        ("finance/customer-service.yaml", {"lane": "customer-service"}),
    ])
    if len(duplicates) != 1 or "finance/customer-service.yaml" not in duplicates[0]:
        raise SystemExit(f"self-test failed: nested duplicate lane names were not reported: {duplicates}")
    if duplicate_lane_errors([
        ("customer-service.yaml", {"lane": "customer-service"}),
        ("operations/field-operations.yaml", {"lane": "field-operations"}),
    ]):
        raise SystemExit("self-test failed: distinct lane names in different folders were rejected")

    fan_in_tier = {"release": {"fan_in": True, "dedicated_prod": False}}
    dedicated_tier = {"release": {"fan_in": False, "dedicated_prod": True}}
    collided = display_name_errors(
        [
            ("a.yaml", {"lane": "foo-bar", "cost_centre": "CC-AB", "tier": "medium", "outside_group": False}),
            ("b.yaml", {"lane": "bar", "cost_centre": "CC-AB-foo", "tier": "medium", "outside_group": False}),
        ],
        {"medium": fan_in_tier},
    )
    if not any("cc-ab-foo-bar-dev" in item for item in collided):
        raise SystemExit(f"self-test failed: slugified display names were not reported as a collision: {collided}")
    distinct = display_name_errors(
        [
            ("customer-service.yaml", {"lane": "customer-service", "cost_centre": "CC-0000", "tier": "medium", "outside_group": False}),
            ("operations/field-operations.yaml", {"lane": "field-operations", "cost_centre": "CC-0000", "tier": "large", "outside_group": False}),
        ],
        {"medium": fan_in_tier, "large": dedicated_tier},
    )
    if distinct:
        raise SystemExit(f"self-test failed: example display names were rejected: {distinct}")
    if environment_display_name("  CC  0000 ", "customer_service", "dev") != "cc-0000-customer-service-dev":
        raise SystemExit("self-test failed: cost centre slug did not match cc-0000-customer-service-dev")
    if environment_display_name("shared", "all-lanes", "test") != "shared-all-lanes-test":
        raise SystemExit("self-test failed: shared fan-in name was not shared-all-lanes-test")
    shared_collision = display_name_errors(
        [
            ("small.yaml", {"lane": "billing", "cost_centre": "CC-0001", "tier": "small", "outside_group": False}),
            ("medium.yaml", {"lane": "claims", "cost_centre": "CC-0002", "tier": "medium", "outside_group": False}),
        ],
        {"small": fan_in_tier, "medium": fan_in_tier},
    )
    if not any("shared-all-lanes-test" in item for item in shared_collision):
        raise SystemExit(f"self-test failed: two fan-in tiers were allowed to share a name: {shared_collision}")
    print("self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0

    errors, warnings = check_repository(args.root)
    for warning in warnings:
        print(f"warning: {warning}")
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"lane policy checks passed ({len(warnings)} advisory warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
