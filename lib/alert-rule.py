#!/usr/bin/env python3
"""Create, patch and delete alert rules.

Split out of the CLI because it builds SQL from user input: keeping it here means
one reviewed place decides which columns are writable and how each value is
typed. The app sends arbitrary JSON, so an allowlist is the control — never
string interpolation of whatever arrives.

    alert-rule.py <id> '{"threshold": 50, "enabled": false}'
    alert-rule.py --create '{"name": "Error spike (api)", "kind": "error_rate",
                             "threshold": 20, "window_secs": 300,
                             "service": "my-api"}'
    alert-rule.py --delete <id>
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# The evaluator's own dispatch table, not a copy of it. A rule whose kind is not
# in here is accepted by the database and then silently never evaluated — it sits
# in the list looking like coverage while checking nothing, which is the worst
# failure this whole feature can have. Importing binds the two together: a kind
# the evaluator cannot run is a kind that cannot be created.
from alerts import CONDITIONS  # noqa: E402

# Only these columns are writable, and each is coerced to its declared type.
# `kind` and `name` are deliberately absent from PATCH: changing a rule's kind
# would orphan its alert_state rows and produce phantom firing/resolved pairs.
WRITABLE = {"threshold", "window_secs", "enabled", "silenced_until", "channels"}

# Creation may set more, because there is no prior state to orphan.
CREATABLE = WRITABLE | {"name", "kind", "target"}

CONTAINER = os.environ.get("PG_CONTAINER", "ai-terminal-logs")
PG_USER = os.environ.get("PG_USER", "logagent")
PG_DB = os.environ.get("PG_DB", "logs")


def literal(key: str, value) -> str:
    if value is None:
        return "NULL"
    if key == "channels":
        items = ",".join('"' + str(v).replace('"', "") + '"' for v in value)
        return "'{" + items + "}'"
    if key == "target":
        return "'" + json.dumps(value).replace("'", "''") + "'::jsonb"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def run_sql(sql: str) -> tuple[bool, str]:
    result = subprocess.run(
        ["docker", "exec", "-i", CONTAINER,
         "psql", "-U", PG_USER, "-d", PG_DB, "-qtAX",
         "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        return False, result.stderr.strip()[:300]
    return True, result.stdout.strip()


def fail(message: str) -> int:
    print(json.dumps({"ok": False, "error": message}))
    return 1


def patch_rule(rule_id: int, patch: dict) -> int:
    assignments = [f"{k} = {literal(k, v)}" for k, v in patch.items() if k in WRITABLE]
    if not assignments:
        return fail("no writable fields in patch")

    ok, err = run_sql(
        f"UPDATE alert_rules SET {', '.join(assignments)} WHERE id = {rule_id};")
    if not ok:
        return fail(err)

    print(json.dumps({"ok": True, "id": rule_id, "applied": sorted(
        k for k in patch if k in WRITABLE)}))
    return 0


def create_rule(spec: dict) -> int:
    name = str(spec.get("name", "")).strip()
    kind = str(spec.get("kind", "")).strip()
    if not name:
        return fail("name is required")
    if kind not in CONDITIONS:
        return fail(
            f"unknown kind '{kind}' — the evaluator would never run it. "
            f"One of: {', '.join(sorted(CONDITIONS))}")

    # A rule scoped to one service, or to all of them. Rules GROUP BY service
    # rather than enumerating it, so "*" means a service deployed tomorrow is
    # covered the moment its first row lands.
    service = str(spec.get("service", "*")).strip() or "*"
    fields = {
        "name": name,
        "kind": kind,
        "target": {"service": service},
        "threshold": spec.get("threshold"),
        "window_secs": int(spec.get("window_secs") or 300),
        "enabled": spec.get("enabled", True),
    }
    if "channels" in spec:
        fields["channels"] = spec["channels"]

    columns = [k for k in fields if k in CREATABLE]
    values = ", ".join(literal(k, fields[k]) for k in columns)
    ok, out = run_sql(
        f"INSERT INTO alert_rules ({', '.join(columns)}) "
        f"VALUES ({values}) RETURNING id;")
    if not ok:
        return fail(out)

    print(json.dumps({"ok": True, "id": int(out or 0), "name": name, "kind": kind}))
    return 0


def delete_rule(rule_id: int) -> int:
    # alert_state has no foreign key, so its rows survive the rule and would be
    # matched by the next rule to reuse the id — a brand new rule inheriting a
    # deleted one's firing state and sending an immediate phantom "resolved".
    ok, err = run_sql(
        f"DELETE FROM alert_state WHERE rule_id = {rule_id}; "
        f"DELETE FROM alert_rules WHERE id = {rule_id};")
    if not ok:
        return fail(err)
    print(json.dumps({"ok": True, "id": rule_id, "deleted": True}))
    return 0


def main() -> int:
    args = sys.argv[1:]
    if not args:
        return fail("usage: alert-rule.py <id> '<patch>' | --create '<json>' | "
                    "--delete <id>")

    try:
        if args[0] == "--create":
            return create_rule(json.loads(args[1]))
        if args[0] == "--delete":
            return delete_rule(int(args[1]))
        return patch_rule(int(args[0]), json.loads(args[1]))
    except (IndexError, ValueError) as exc:
        return fail(f"bad arguments: {exc}")


if __name__ == "__main__":
    sys.exit(main())
