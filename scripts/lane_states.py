#!/usr/bin/env python3
"""Cost-centre state keys for the lanes stack.

The slug matches modules/lane: trim, lowercase, spaces and underscores become
hyphens, repeated hyphens collapse, and surrounding hyphens are removed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parents[1]
SHARED = "shared"
SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
LANE_ADDRESS = re.compile(
    r'^(?:module\.(?:dev|dedicated_test|dedicated_prod)|terraform_data\.lane_rules)\["([^"]+)"\]'
)
FULL_PREFIXES = (
    "modules/",
    "stacks/",
    "tiers/",
    ".github/workflows/",
    ".github/actions/",
)


def slug(value: str) -> str:
    text = str(value).strip().lower().replace(" ", "-").replace("_", "-")
    text = re.sub(r"-{2,}", "-", text)
    return text.strip("-")


def state_key(cost_centre_slug: str) -> str:
    return f"lanes/{cost_centre_slug}.tfstate"


def state_entry(cost_centre_slug: str) -> dict[str, str]:
    return {
        "cost_centre": cost_centre_slug,
        "state_key": state_key(cost_centre_slug),
        "plan_label": f"lanes-{cost_centre_slug}",
    }


def load_lane_slugs(root: Path) -> dict[str, str]:
    if yaml is None:
        raise SystemExit("PyYAML is required. Install it with: python3 -m pip install pyyaml")
    lanes_dir = root / "lanes"
    found: dict[str, str] = {}
    if not lanes_dir.is_dir():
        return found
    for path in sorted(lanes_dir.rglob("*.yaml")):
        if any(part.startswith(".") for part in path.relative_to(lanes_dir).parts):
            continue
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            continue
        name = data.get("lane")
        centre = data.get("cost_centre")
        if isinstance(name, str) and name and isinstance(centre, str):
            found[name] = slug(centre)
    return found


def cost_centre_slugs(root: Path) -> list[str]:
    return sorted({value for value in load_lane_slugs(root).values() if value and value != SHARED})


def classify(addresses: list[str], lane_slugs: dict[str, str]) -> dict[str, list[str]]:
    """Split state addresses into per-target lists, plus copy and drop.

    copy stays in every target state (tier checks, auth marker, root data sources).
    drop leaves state entirely (the tenant-wide environment catalogue).
    """
    targets: dict[str, list[str]] = {SHARED: []}
    for centre in sorted(set(lane_slugs.values())):
        if centre and centre != SHARED:
            targets.setdefault(centre, [])
    copy: list[str] = []
    drop: list[str] = []
    unknown: list[str] = []

    for address in addresses:
        match = LANE_ADDRESS.match(address)
        if match:
            lane_name = match.group(1)
            centre = lane_slugs.get(lane_name)
            if not centre or centre == SHARED:
                unknown.append(address)
                continue
            targets.setdefault(centre, []).append(address)
            continue
        if address.startswith("module.shared_test") or address.startswith("module.shared_prod") or address.startswith("module.dlp"):
            targets[SHARED].append(address)
            continue
        if (
            address.startswith("module.tier[")
            or address == "terraform_data.auth_mode"
            or address.startswith("data.azuread_client_config.")
            or address.startswith("data.terraform_remote_state.groups")
        ):
            copy.append(address)
            continue
        if address.startswith("data.powerplatform_environments.") or address == "terraform_data.display_names":
            drop.append(address)
            continue
        unknown.append(address)

    return {"targets": targets, "copy": copy, "drop": drop, "unknown": unknown}


def matrix_for_changes(changed: list[str] | None, root: Path, full: bool = False) -> dict:
    slugs = cost_centre_slugs(root)
    entries = [state_entry(centre) for centre in slugs]
    shared_entry = state_entry(SHARED)
    if full or changed is None:
        return {"run": True, "shared": True, "cost_centres": entries, "shared_state": shared_entry}

    selected: set[str] = set()
    include_shared = False
    force_all = False
    for raw in changed:
        path = raw.strip().lstrip("./")
        if not path:
            continue
        if path.startswith(FULL_PREFIXES):
            force_all = True
            break
        if path.startswith("lanes/") and path.endswith((".yaml", ".yml")):
            file_path = root / path
            if not file_path.is_file():
                force_all = True
                break
            if yaml is None:
                raise SystemExit("PyYAML is required. Install it with: python3 -m pip install pyyaml")
            data = yaml.safe_load(file_path.read_text(encoding="utf-8"))
            centre = slug(str(data.get("cost_centre", ""))) if isinstance(data, dict) else ""
            if not centre or centre == SHARED or centre not in slugs:
                force_all = True
                break
            selected.add(centre)
            include_shared = True
    if force_all:
        return {"run": True, "shared": True, "cost_centres": entries, "shared_state": shared_entry}
    if not selected and not include_shared:
        return {"run": False, "shared": False, "cost_centres": [], "shared_state": shared_entry}
    chosen = [item for item in entries if item["cost_centre"] in selected]
    return {"run": True, "shared": include_shared, "cost_centres": chosen, "shared_state": shared_entry}


def write_github_output(payload: dict, path: Path) -> None:
    centres = payload["cost_centres"]
    # GitHub rejects an empty matrix. The job if skips this placeholder.
    matrix = centres or [state_entry("skipped")]
    line = {"separators": (",", ":")}
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"run={'true' if payload['run'] else 'false'}\n")
        handle.write(f"shared={'true' if payload['shared'] else 'false'}\n")
        handle.write(f"cost_centres={json.dumps(centres, **line)}\n")
        handle.write(f"matrix={json.dumps(matrix, **line)}\n")
        handle.write(f"shared_state={json.dumps(payload['shared_state'], **line)}\n")


def self_test() -> None:
    if slug("  CC  0000 ") != "cc-0000":
        raise SystemExit("self-test failed: CC-0000 did not slug to cc-0000")
    if slug("shared") != SHARED or state_key("cc-0000") != "lanes/cc-0000.tfstate":
        raise SystemExit("self-test failed: state key")
    if not SLUG_RE.fullmatch(slug("CC-0000")):
        raise SystemExit("self-test failed: slug pattern")

    lane_slugs = {"customer-service": "cc-0000", "field-operations": "cc-0000", "billing": "cc-0001"}
    addresses = [
        'module.dev["customer-service"].powerplatform_environment.this',
        'module.dev["billing"].powerplatform_environment.this',
        'module.dev["field-operations"].azuread_group.this',
        'terraform_data.lane_rules["customer-service"]',
        "module.dlp[\"medium\"].powerplatform_data_loss_prevention_policy.this[0]",
        "module.shared_test[\"medium\"].powerplatform_environment.this",
        'module.tier["medium.yaml"].terraform_data.tier',
        "terraform_data.auth_mode",
        "data.powerplatform_environments.catalogue[0]",
        "terraform_data.display_names",
        "data.azuread_client_config.caller",
    ]
    result = classify(addresses, lane_slugs)
    if result["unknown"]:
        raise SystemExit(f"self-test failed: unknown addresses {result['unknown']}")
    cc = result["targets"]["cc-0000"]
    if 'module.dev["customer-service"].powerplatform_environment.this' not in cc:
        raise SystemExit("self-test failed: dev environment was not kept on cc-0000")
    if 'module.dev["billing"].powerplatform_environment.this' in cc:
        raise SystemExit("self-test failed: billing stayed on cc-0000")
    if 'module.dev["billing"].powerplatform_environment.this' not in result["targets"]["cc-0001"]:
        raise SystemExit("self-test failed: billing was not sent to cc-0001")
    if "module.dlp" in " ".join(cc):
        raise SystemExit("self-test failed: data policy was left on the cost centre state")
    shared = result["targets"][SHARED]
    if not any(item.startswith("module.dlp") for item in shared):
        raise SystemExit("self-test failed: data policy was not sent to shared")
    if not any(item.startswith("module.shared_test") for item in shared):
        raise SystemExit("self-test failed: fan-in environment was not sent to shared")
    if "data.powerplatform_environments.catalogue[0]" not in result["drop"]:
        raise SystemExit("self-test failed: catalogue data source was not dropped")
    if "terraform_data.auth_mode" not in result["copy"]:
        raise SystemExit("self-test failed: auth marker was not copied")

    repo = matrix_for_changes(["lanes/customer-service.yaml"], ROOT)
    if [item["cost_centre"] for item in repo["cost_centres"]] != ["cc-0000"] or not repo["shared"]:
        raise SystemExit(f"self-test failed: lane change matrix {repo}")
    if repo["cost_centres"][0]["plan_label"] != "lanes-cc-0000" or repo["cost_centres"][0]["state_key"] != "lanes/cc-0000.tfstate":
        raise SystemExit(f"self-test failed: plan label {repo['cost_centres'][0]}")
    if repo["shared_state"]["plan_label"] != "lanes-shared":
        raise SystemExit("self-test failed: shared plan label")
    broad = matrix_for_changes(["modules/lane/main.tf"], ROOT)
    if [item["cost_centre"] for item in broad["cost_centres"]] != ["cc-0000"] or not broad["shared"]:
        raise SystemExit(f"self-test failed: module change should plan every lanes state {broad}")
    quiet = matrix_for_changes(["README.md"], ROOT)
    if quiet["run"] or quiet["cost_centres"]:
        raise SystemExit(f"self-test failed: README should not plan lanes {quiet}")
    tenant_only = matrix_for_changes(["tenant/baseline.yaml"], ROOT)
    if tenant_only["run"] or tenant_only["shared"]:
        raise SystemExit(f"self-test failed: tenant baseline should not plan lanes {tenant_only}")
    missing = matrix_for_changes(["lanes/retired.yaml"], ROOT)
    if [item["cost_centre"] for item in missing["cost_centres"]] != ["cc-0000"] or not missing["run"]:
        raise SystemExit(f"self-test failed: a deleted lane file should plan every lanes state {missing}")
    print("lane state self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--root", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="command")

    matrix = sub.add_parser("matrix")
    matrix.add_argument("--all", action="store_true")
    matrix.add_argument("--changed-file", action="append", default=[])
    matrix.add_argument("--github-output", type=Path)

    sub.add_parser("slugs")

    classify_cmd = sub.add_parser("classify")
    classify_cmd.add_argument("--addresses", type=Path, required=True)

    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.command == "matrix":
        payload = matrix_for_changes(None if args.all else args.changed_file, args.root, full=args.all)
        if args.github_output:
            write_github_output(payload, args.github_output)
        else:
            print(json.dumps(payload))
        return 0
    if args.command == "slugs":
        for centre in cost_centre_slugs(args.root):
            print(centre)
        return 0
    if args.command == "classify":
        addresses = [line.strip() for line in args.addresses.read_text(encoding="utf-8").splitlines() if line.strip()]
        result = classify(addresses, load_lane_slugs(args.root))
        print(json.dumps(result))
        if result["unknown"]:
            return 1
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
