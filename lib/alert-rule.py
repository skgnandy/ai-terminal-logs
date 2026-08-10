#!/usr/bin/env python3
"""Apply a JSON patch to one alert rule.

Split out of the CLI because it builds SQL from user input: keeping it here means
one reviewed place decides which columns are writable and how each value is
typed. The app sends arbitrary JSON, so an allowlist is the control — never
string interpolation of whatever arrives.

    alert-rule.py <id> '{"threshold": 50, "enabled": false}'
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

# Only these columns are writable, and each is coerced to its declared type.
# `kind` and `name` are deliberately absent: changing a rule's kind would orphan
# its alert_state rows and produce phantom firing/resolved pairs.
WRITABLE = {"threshold", "window_secs", "enabled", "silenced_until", "channels"}


def literal(key: str, value) -> str:
    if value is None:
        return "NULL"
    if key == "channels":
        items = ",".join('"' + str(v).replace('"', "") + '"' for v in value)
        return "'{" + items + "}'"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def main() -> int:
    try:
        rule_id = int(sys.argv[1])
        patch = json.loads(sys.argv[2])
    except (IndexError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": f"bad arguments: {exc}"}))
        return 1

    assignments = [f"{k} = {literal(k, v)}" for k, v in patch.items() if k in WRITABLE]
    if not assignments:
        print(json.dumps({"ok": False, "error": "no writable fields in patch"}))
        return 1

    sql = f"UPDATE alert_rules SET {', '.join(assignments)} WHERE id = {rule_id};"
    result = subprocess.run(
        ["docker", "exec", "-i", os.environ.get("PG_CONTAINER", "ai-terminal-logs"),
         "psql", "-U", os.environ.get("PG_USER", "logagent"),
         "-d", os.environ.get("PG_DB", "logs"), "-qtAX",
         "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        print(json.dumps({"ok": False, "error": result.stderr.strip()[:300]}))
        return 1

    print(json.dumps({"ok": True, "id": rule_id, "applied": sorted(
        k for k in patch if k in WRITABLE)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
