#!/usr/bin/env python3
"""Classify a Terraform JSON plan for the nightly drift check.

A plan is benign when every resource change is a no-op, a read, or an in-place
update of powerplatform_data_loss_prevention_policy that only adds connectors
to blocked_connectors. Those connectors are already blocked by the policy
default. last_modified_by, last_modified_time, and any value Terraform marks
unknown after apply are ignored. Any other change, including an output change,
is drift.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

QUIET_ACTIONS = {"no-op", "read"}
IGNORED_ATTRIBUTES = {"last_modified_by", "last_modified_time"}
DLP_TYPE = "powerplatform_data_loss_prevention_policy"
_UNKNOWN = object()


def classify(plan: dict) -> dict:
    """Return classification, new connector ids, per-resource additions, and reasons."""
    if not isinstance(plan, dict):
        return _result("drift", [], [], ["plan JSON must be an object"])

    reasons = output_reasons(plan.get("output_changes"))
    resources = plan.get("resource_changes")
    if not isinstance(resources, list):
        reasons.append("plan JSON is missing resource_changes")
        resources = []

    additions: list[dict] = []
    for resource in resources:
        if not isinstance(resource, dict):
            reasons.append("a resource change was not an object")
            continue
        outcome = inspect_resource(resource)
        if outcome is None:
            continue
        if outcome["benign"]:
            additions.append(
                {
                    "address": outcome["address"],
                    "connector_ids": outcome["connector_ids"],
                }
            )
            continue
        reasons.extend(outcome["reasons"])

    connector_ids = sorted({cid for item in additions for cid in item["connector_ids"]})
    if reasons:
        return _result("drift", connector_ids, additions, reasons)
    if additions:
        return _result("benign", connector_ids, additions, [])
    return _result("clean", [], [], [])


def output_reasons(output_changes) -> list[str]:
    if output_changes is None:
        return []
    if not isinstance(output_changes, dict):
        return ["output_changes was not an object"]
    reasons = []
    for name in sorted(output_changes):
        change = output_changes[name]
        if not isinstance(change, dict):
            reasons.append(f"output {name} is not an object")
            continue
        actions = change.get("actions")
        if actions == ["no-op"]:
            continue
        reasons.append(f"output {name} actions {actions}")
    return reasons


def inspect_resource(resource: dict) -> dict | None:
    address = str(resource.get("address") or "<unknown address>")
    change = resource.get("change")
    if not isinstance(change, dict):
        return _outcome(address, False, [f"{address} has no change object"], [])
    actions = change.get("actions")
    if isinstance(actions, list) and actions and all(action in QUIET_ACTIONS for action in actions):
        return None
    if _is_dlp(resource) and actions == ["update"]:
        benign, reasons, connector_ids = dlp_update_is_benign(address, change)
        return _outcome(address, benign, reasons, connector_ids)
    resource_type = resource.get("type") or "<unknown type>"
    return _outcome(address, False, [f"{address} ({resource_type}) actions {actions}"], [])


def dlp_update_is_benign(address: str, change: dict) -> tuple[bool, list[str], list[str]]:
    before = change.get("before")
    after = change.get("after")
    unknown = change.get("after_unknown")
    if not isinstance(before, dict) or not isinstance(after, dict):
        return False, [f"{address} update is missing before or after values"], []
    if unknown is True:
        return False, [f"{address} planned values are unknown after apply"], []

    blocked_unknown = unknown.get("blocked_connectors") if isinstance(unknown, dict) else False
    superset, new_ids = blocked_is_superset(
        before.get("blocked_connectors"),
        after.get("blocked_connectors"),
        blocked_unknown,
    )
    reasons = []
    if not superset:
        reasons.append(f"{address} blocked_connectors is not a superset of the current list")
    equal, changed = other_attributes_equal(before, after, unknown)
    if not equal:
        reasons.append(f"{address} changed attributes: {', '.join(changed)}")
    if reasons:
        return False, reasons, []
    return True, [], _dedupe(new_ids)


def blocked_is_superset(before_value, after_value, unknown) -> tuple[bool, list[str]]:
    """True when every current blocked connector is still present.

    Order does not matter. Extra connectors in the planned list are the additions.
    A value Terraform cannot show is not treated as a superset.
    """
    before_list = _as_list(before_value)
    after_list = _as_list(after_value)
    if before_list is None or after_list is None:
        return False, []
    if _fully_known(unknown):
        return _superset_known(before_list, after_list)

    masks = _masks_for(unknown, len(after_list))
    if masks is None:
        return False, []
    used = [False] * len(after_list)
    for before_item in before_list:
        found = None
        for index, after_item in enumerate(after_list):
            if used[index]:
                continue
            if _visible(before_item, masks[index]) == _visible(after_item, masks[index]):
                found = index
                break
        if found is None:
            return False, []
        used[found] = True
    new_ids = [
        _connector_id(after_list[index], masks[index])
        for index, chosen in enumerate(used)
        if not chosen
    ]
    return True, new_ids


def other_attributes_equal(before: dict, after: dict, unknown) -> tuple[bool, list[str]]:
    if unknown is True:
        return False, ["<planned values>"]
    unk = unknown if isinstance(unknown, dict) else {}
    keys = (set(before) | set(after) | set(unk)) - {"blocked_connectors"} - IGNORED_ATTRIBUTES
    changed = []
    for key in sorted(keys):
        flag = unk.get(key, False)
        if flag is True:
            continue
        if _visible(before.get(key), flag) != _visible(after.get(key), flag):
            changed.append(key)
    return (not changed), changed


def benign_message(result: dict, plan_label: str) -> str:
    where = f"stacks/{plan_label}" if plan_label else "this stack"
    ids = result["connector_ids"]
    if ids:
        text = (
            f"{where} plan only adds connectors to blocked_connectors. "
            "They are already blocked by the policy default. "
            f"No drift issue opened. New connector ids: {', '.join(ids)}"
        )
    else:
        text = (
            f"{where} plan only changes computed fields on data loss prevention policies. "
            "No drift issue opened."
        )
    return _one_line(text)


def summary_lines(result: dict, plan_label: str) -> list[str]:
    where = f"stacks/{plan_label}" if plan_label else "this stack"
    lines = [
        f"### Benign data policy drift ({where})",
        "",
        "The plan only adds connectors to `blocked_connectors` on data loss prevention policies. "
        "The policy default is already Blocked, so a new catalogue connector is blocked before this plan is applied. "
        "This job did not open or update a drift issue. The next apply records the new ids.",
        "",
    ]
    if any(item["connector_ids"] for item in result["additions"]):
        lines.append("| Resource | New connector ids |")
        lines.append("| --- | --- |")
        for item in result["additions"]:
            address = str(item["address"]).replace("|", "/")
            if item["connector_ids"]:
                rendered = ", ".join(f"`{cid}`" for cid in item["connector_ids"])
            else:
                rendered = "(computed fields only)"
            lines.append(f"| `{address}` | {rendered} |")
    else:
        lines.append(
            "No new connector ids. The remaining diff is computed fields "
            "such as `last_modified_by` and `last_modified_time`."
        )
    lines.append("")
    return lines


def write_github_output(path: Path, result: dict) -> None:
    connectors = json.dumps(result["connector_ids"], separators=(",", ":"))
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"drift_class={result['classification']}\n")
        handle.write(f"drift_connectors={connectors}\n")


def emit_benign_notice(result: dict, plan_label: str) -> None:
    message = benign_message(result, plan_label)
    print(message)
    print(f"::notice title=Benign data policy drift::{message}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary:
        return
    with open(summary, "a", encoding="utf-8") as handle:
        handle.write("\n".join(summary_lines(result, plan_label)))
        handle.write("\n")


def load_plan(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SystemExit(f"Could not read plan JSON {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Plan JSON {path} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"Plan JSON {path} must be an object")
    return data


def _result(classification: str, connector_ids: list[str], additions: list[dict], reasons: list[str]) -> dict:
    return {
        "classification": classification,
        "connector_ids": connector_ids,
        "additions": additions,
        "reasons": reasons,
    }


def _outcome(address: str, benign: bool, reasons: list[str], connector_ids: list[str]) -> dict:
    return {
        "address": address,
        "benign": benign,
        "reasons": reasons,
        "connector_ids": connector_ids,
    }


def _is_dlp(resource: dict) -> bool:
    if resource.get("type") != DLP_TYPE:
        return False
    return resource.get("mode", "managed") == "managed"


def _as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return None


def _fully_known(unknown) -> bool:
    if unknown in (None, False):
        return True
    if unknown is True:
        return False
    if isinstance(unknown, dict):
        return all(_fully_known(item) for item in unknown.values())
    if isinstance(unknown, list):
        return all(_fully_known(item) for item in unknown)
    return False


def _masks_for(unknown, length: int):
    if unknown is True:
        return None
    if isinstance(unknown, dict):
        return [unknown] * length
    if isinstance(unknown, list):
        if len(unknown) == length:
            return unknown
        if len(unknown) == 1:
            return unknown * length
    return None


def _superset_known(before_list: list, after_list: list) -> tuple[bool, list[str]]:
    try:
        before_counts = Counter(_canonical(item) for item in before_list)
        after_counts = Counter(_canonical(item) for item in after_list)
    except TypeError:
        return False, []
    for key, count in before_counts.items():
        if after_counts[key] < count:
            return False, []
    seen: Counter = Counter()
    new_ids = []
    for item in after_list:
        key = _canonical(item)
        seen[key] += 1
        if seen[key] > before_counts[key]:
            new_ids.append(_connector_id(item, False))
    return True, new_ids


def _visible(value, unknown):
    if unknown is True:
        return _UNKNOWN
    if isinstance(value, dict):
        unk = unknown if isinstance(unknown, dict) else {}
        shown = {}
        for key in sorted(value):
            if key in IGNORED_ATTRIBUTES:
                continue
            child = unk.get(key, False)
            if child is True:
                continue
            shown[key] = _visible(value[key], child)
        return shown
    if isinstance(value, list):
        if isinstance(unknown, list) and len(unknown) == len(value):
            return [_visible(item, flag) for item, flag in zip(value, unknown)]
        if isinstance(unknown, dict):
            return [_visible(item, unknown) for item in value]
        if isinstance(unknown, list) and len(unknown) == 1:
            return [_visible(item, unknown[0]) for item in value]
        return [_visible(item, False) for item in value]
    return value


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _connector_id(item, unknown) -> str:
    if isinstance(unknown, dict) and unknown.get("id") is True:
        return "<unknown>"
    if isinstance(item, dict):
        cid = item.get("id")
        if isinstance(cid, str) and cid:
            return cid
    try:
        return _canonical(item)
    except TypeError:
        return "<unknown>"


def _dedupe(ids: list[str]) -> list[str]:
    seen = set()
    ordered = []
    for cid in ids:
        if cid not in seen:
            seen.add(cid)
            ordered.append(cid)
    return ordered


def _one_line(text: str) -> str:
    return " ".join(text.replace("::", " ").split())


def self_test() -> None:
    sql = "/providers/Microsoft.PowerApps/apis/shared_sql"
    twitter = "/providers/Microsoft.PowerApps/apis/shared_twitter"
    dataverse = "/providers/Microsoft.PowerApps/apis/shared_commondataservice"
    office = "/providers/Microsoft.PowerApps/apis/shared_office365users"
    stackiq = "/providers/Microsoft.PowerApps/apis/shared_stackiq"
    medium = 'module.dlp["medium"].powerplatform_data_loss_prevention_policy.this[0]'
    large = 'module.dlp["large"].powerplatform_data_loss_prevention_policy.this[0]'

    def connector(cid: str, rules: list | None = None) -> dict:
        return {
            "action_rules": [] if rules is None else rules,
            "default_action_rule_behavior": "",
            "endpoint_rules": [],
            "id": cid,
        }

    def policy(blocked: list, **overrides) -> dict:
        body = {
            "blocked_connectors": json.loads(json.dumps(blocked)),
            "business_connectors": [connector(dataverse)],
            "created_time": "2026-01-01T00:00:00Z",
            "custom_connectors_patterns": [
                {"data_group": "NonBusiness", "host_url_pattern": "*", "order": 1}
            ],
            "default_connectors_classification": "Blocked",
            "display_name": "Medium",
            "environment_type": "OnlyEnvironments",
            "environments": ["env-1"],
            "id": "policy-1",
            "last_modified_by": "Service Principal (abc)",
            "last_modified_time": "2026-10-21T12:01:58Z",
            "non_business_connectors": [connector(office)],
        }
        body.update(overrides)
        return body

    def dlp_update(
        before_blocked: list,
        after_blocked: list,
        address: str,
        mutate_after=None,
        actions=None,
        after_unknown=None,
    ) -> dict:
        before = policy(before_blocked)
        after = policy(after_blocked)
        after["last_modified_by"] = "someone else"
        after["last_modified_time"] = None
        after["created_time"] = None
        if mutate_after:
            mutate_after(after)
        unknown = {
            "blocked_connectors": False,
            "created_time": True,
            "last_modified_by": False,
            "last_modified_time": True,
        }
        if after_unknown:
            unknown.update(after_unknown)
        return {
            "address": address,
            "mode": "managed",
            "type": DLP_TYPE,
            "name": "this",
            "change": {
                "actions": ["update"] if actions is None else actions,
                "after": after,
                "after_unknown": unknown,
                "before": before,
            },
        }

    def read_catalogue() -> dict:
        return {
            "address": 'module.dlp["medium"].data.powerplatform_connectors.all[0]',
            "mode": "data",
            "type": "powerplatform_connectors",
            "change": {"actions": ["read"], "before": None, "after": {"connectors": []}},
        }

    def noop_environment() -> dict:
        return {
            "address": 'module.shared_test["medium"].powerplatform_environment.this',
            "mode": "managed",
            "type": "powerplatform_environment",
            "change": {
                "actions": ["no-op"],
                "before": {"display_name": "shared-all-lanes-test"},
                "after": {"display_name": "shared-all-lanes-test"},
            },
        }

    def environment_update() -> dict:
        return {
            "address": 'module.dev["customer-service"].powerplatform_environment.this',
            "mode": "managed",
            "type": "powerplatform_environment",
            "change": {
                "actions": ["update"],
                "before": {"display_name": "cc-0000-customer-service-dev"},
                "after": {"display_name": "renamed"},
                "after_unknown": {},
            },
        }

    def outputs(actions: list[str], after: dict) -> dict:
        return {
            "policy_ids": {
                "actions": actions,
                "before": {"medium": "policy-1"},
                "after": after,
                "after_unknown": False,
            }
        }

    def plan_with(*resources, output_changes=None) -> dict:
        return {
            "resource_changes": list(resources),
            "output_changes": {} if output_changes is None else output_changes,
        }

    def check(plan: dict, expected: str, label: str) -> dict:
        plan = json.loads(json.dumps(plan))
        result = classify(plan)
        if result["classification"] != expected:
            raise SystemExit(f"self-test failed: {label}: {json.dumps(result)}")
        if expected == "drift" and not result["reasons"]:
            raise SystemExit(f"self-test failed: {label}: drift had no reasons")
        if expected != "drift" and result["reasons"]:
            raise SystemExit(f"self-test failed: {label}: unexpected reasons {result['reasons']}")
        return result

    def reason_text(result: dict) -> str:
        return " ".join(result["reasons"])

    current = [connector(sql), connector(twitter)]
    added = [connector(twitter), connector(stackiq), connector(sql)]
    benign = plan_with(
        read_catalogue(),
        noop_environment(),
        dlp_update(current, added, medium),
        dlp_update(current, added, large),
        output_changes=outputs(["no-op"], {"medium": "policy-1"}),
    )
    result = check(benign, "benign", "benign-only blocked additions")
    if result["connector_ids"] != [stackiq]:
        raise SystemExit(f"self-test failed: new connector ids {result['connector_ids']}")
    if {item["address"] for item in result["additions"]} != {medium, large}:
        raise SystemExit(f"self-test failed: additions {result['additions']}")
    for item in result["additions"]:
        if item["connector_ids"] != [stackiq]:
            raise SystemExit(f"self-test failed: per-resource ids {item}")
    if stackiq not in benign_message(result, "lanes-shared"):
        raise SystemExit("self-test failed: notice omitted the new connector id")
    summary = "\n".join(summary_lines(result, "lanes-shared"))
    if stackiq not in summary or medium not in summary:
        raise SystemExit("self-test failed: job summary omitted the connector or the resource")

    computed = check(
        plan_with(dlp_update([connector(sql)], [connector(sql)], medium)),
        "benign",
        "computed last_modified fields only",
    )
    if computed["connector_ids"]:
        raise SystemExit(f"self-test failed: computed-only plan listed ids {computed['connector_ids']}")

    def blank_behaviour(after: dict) -> None:
        for item in after["blocked_connectors"]:
            item["default_action_rule_behavior"] = None

    unknown_attr = check(
        plan_with(
            dlp_update(
                [connector(sql)],
                [connector(sql), connector(stackiq)],
                medium,
                mutate_after=blank_behaviour,
                after_unknown={"blocked_connectors": {"default_action_rule_behavior": True}},
            )
        ),
        "benign",
        "unknown connector attribute ignored",
    )
    if unknown_attr["connector_ids"] != [stackiq]:
        raise SystemExit(f"self-test failed: masked addition ids {unknown_attr['connector_ids']}")

    moved = check(
        plan_with(dlp_update(current, [connector(sql), connector(stackiq)], medium)),
        "drift",
        "connector moved out of blocked",
    )
    if "blocked_connectors" not in reason_text(moved):
        raise SystemExit(f"self-test failed: moved connector reasons {moved['reasons']}")

    def add_business(after: dict) -> None:
        after["business_connectors"] = list(after["business_connectors"]) + [connector(stackiq)]

    business = check(
        plan_with(dlp_update(current, current, medium, mutate_after=add_business)),
        "drift",
        "business list change",
    )
    if "business_connectors" not in reason_text(business):
        raise SystemExit(f"self-test failed: business list reasons {business['reasons']}")

    def add_non_business(after: dict) -> None:
        after["non_business_connectors"] = list(after["non_business_connectors"]) + [connector(stackiq)]

    non_business = check(
        plan_with(dlp_update(current, current, medium, mutate_after=add_non_business)),
        "drift",
        "non-business list change",
    )
    if "non_business_connectors" not in reason_text(non_business):
        raise SystemExit(f"self-test failed: non-business list reasons {non_business['reasons']}")

    def rename(after: dict) -> None:
        after["display_name"] = "Medium renamed"

    renamed = check(
        plan_with(dlp_update(current, current, medium, mutate_after=rename)),
        "drift",
        "another attribute change",
    )
    if "display_name" not in reason_text(renamed):
        raise SystemExit(f"self-test failed: attribute reasons {renamed['reasons']}")

    def change_rules(after: dict) -> None:
        after["blocked_connectors"] = [connector(sql), connector(twitter, rules=[{"action": "Block"}])]

    rules = check(
        plan_with(dlp_update(current, current, medium, mutate_after=change_rules)),
        "drift",
        "existing blocked connector rule change",
    )
    if "blocked_connectors" not in reason_text(rules):
        raise SystemExit(f"self-test failed: rule change reasons {rules['reasons']}")

    replaced = check(
        plan_with(dlp_update(current, added, medium, actions=["delete", "create"])),
        "drift",
        "data policy replace",
    )
    if "actions" not in reason_text(replaced):
        raise SystemExit(f"self-test failed: replace reasons {replaced['reasons']}")

    other = check(
        plan_with(read_catalogue(), environment_update()),
        "drift",
        "non-DLP resource change",
    )
    if "powerplatform_environment" not in reason_text(other):
        raise SystemExit(f"self-test failed: non-DLP reasons {other['reasons']}")

    mixed = check(
        plan_with(dlp_update(current, added, medium), environment_update()),
        "drift",
        "benign data policy change plus a non-DLP resource change",
    )
    if "powerplatform_environment" not in reason_text(mixed):
        raise SystemExit(f"self-test failed: mixed resource reasons {mixed['reasons']}")

    outputs_only = check(
        plan_with(read_catalogue(), noop_environment(), output_changes=outputs(["update"], {"medium": "policy-2"})),
        "drift",
        "outputs-only plan",
    )
    if "output policy_ids" not in reason_text(outputs_only):
        raise SystemExit(f"self-test failed: output reasons {outputs_only['reasons']}")

    with_output = check(
        plan_with(
            dlp_update(current, added, medium),
            output_changes=outputs(["update"], {"medium": "policy-2"}),
        ),
        "drift",
        "benign data policy change plus an output change",
    )
    if "output policy_ids" not in reason_text(with_output):
        raise SystemExit(f"self-test failed: output plus policy reasons {with_output['reasons']}")

    check({"output_changes": {}}, "drift", "plan JSON missing resource_changes")
    check(
        plan_with(read_catalogue(), noop_environment(), output_changes=outputs(["no-op"], {"medium": "policy-1"})),
        "clean",
        "quiet plan",
    )

    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        plan_path = directory / "plan.json"
        output_path = directory / "github_output"
        plan_path.write_text(json.dumps(benign), encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--plan",
                str(plan_path),
                "--plan-label",
                "lanes-shared",
                "--github-output",
                str(output_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            raise SystemExit(f"self-test failed: cli exit {completed.returncode}: {completed.stderr}")
        payload, _end = json.JSONDecoder().raw_decode(completed.stdout)
        if payload["classification"] != "benign" or payload["connector_ids"] != [stackiq]:
            raise SystemExit(f"self-test failed: cli payload {payload}")
        if stackiq not in completed.stdout or "No drift issue opened" not in completed.stdout:
            raise SystemExit("self-test failed: cli notice omitted the connector id")
        written = output_path.read_text(encoding="utf-8").splitlines()
        if "drift_class=benign" not in written:
            raise SystemExit(f"self-test failed: github output {written}")
        if not any(line.startswith("drift_connectors=") and stackiq in line for line in written):
            raise SystemExit(f"self-test failed: github connector output {written}")

    print("drift classification self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--plan-label", default="")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.plan is None:
        parser.error("--plan is required")
    result = classify(load_plan(args.plan))
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    if args.github_output:
        write_github_output(args.github_output, result)
    if result["classification"] == "benign":
        emit_benign_notice(result, args.plan_label)
    return 0


if __name__ == "__main__":
    sys.exit(main())
