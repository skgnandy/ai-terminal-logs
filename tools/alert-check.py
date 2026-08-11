#!/usr/bin/env python3
"""Check the alert evaluator without a machine.

    tools/alert-check.py

Three things, none of which need Postgres, Docker or the target host:

  1. Every condition query parses under the real Postgres grammar. A syntax
     error in one of these does not crash anything — q() swallows it and
     returns no rows — so the rule simply never fires, which is the worst way
     for an alert to fail.

  2. Every kind in the dispatch table has a message template. A kind without
     one sends a notification reading "None", and it is discovered by the
     person being paged.

  3. The scope filter restricts a rule to the service it was written for.
     Rules carry target.service, which the evaluator ignored for a long time:
     a rule scoped to one service fired for every service.

Requires pglast (`pip install pglast`) for (1); (2) and (3) run regardless, so
this is still useful on a machine without it.
"""
from __future__ import annotations

import importlib.util
import os
import sys

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib")


def load_alerts():
    """Import lib/alerts.py by path — it is not on the import path, and its
    filename neighbours (alert-rule.py) are not importable as modules."""
    spec = importlib.util.spec_from_file_location(
        "alerts", os.path.join(LIB, "alerts.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules["alerts"] = module
    spec.loader.exec_module(module)
    return module


def check_sql(alerts) -> bool:
    try:
        import pglast
    except ImportError:
        print("skip  SQL parse — pglast not installed (pip install pglast)")
        return True

    captured: list[str] = []
    alerts.q = lambda sql: captured.append(sql) or []

    ok = True
    for kind, fn in sorted(alerts.CONDITIONS.items()):
        captured.clear()
        try:
            fn(90.0, 900)
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL  {kind}: building the query raised {exc}")
            ok = False
            continue
        if not captured:
            print(f"FAIL  {kind}: built no SQL at all")
            ok = False
            continue
        for sql in captured:
            try:
                pglast.parse_sql(sql)
            except Exception as exc:  # noqa: BLE001
                print(f"FAIL  {kind}: {exc}")
                ok = False
                break
        else:
            print(f"ok    {kind} parses")
    return ok


def check_messages(alerts) -> bool:
    missing = sorted(set(alerts.CONDITIONS) - set(alerts.MESSAGES))
    extra = sorted(set(alerts.MESSAGES) - set(alerts.CONDITIONS))
    if missing:
        print(f"FAIL  kinds with no message template: {', '.join(missing)}")
    if extra:
        print(f"FAIL  message templates with no condition: {', '.join(extra)}")
    if not missing and not extra:
        print(f"ok    {len(alerts.CONDITIONS)} kinds, each with a message")
    return not missing and not extra


def check_scope(alerts) -> bool:
    services = {"api": "12", "worker": "9"}
    endpoints = {
        "api  GET /leads/:id": "9400",
        "api  POST /login": "620",
        "worker  GET /health": "3100",
    }
    cases = [
        ("wildcard keeps every service",
         ("cpu", "*", services), services),
        ("a service scope keeps only that service",
         ("cpu", "worker", services), {"worker": "9"}),
        ("a service scope matches endpoint keys by prefix",
         ("endpoint_latency", "api", endpoints),
         {"api  GET /leads/:id": "9400", "api  POST /login": "620"}),
        # The reason the separator is two spaces and the match is not a bare
        # startswith on the name: one service must not capture another whose
        # name begins with the same text.
        ("a service that is a prefix of another captures nothing of its",
         ("endpoint_latency", "ap", endpoints), {}),
        ("disk ignores scope — its key is the machine, not a service",
         ("disk", "worker", {"_host_": "91"}), {"_host_": "91"}),
        ("cert_expiry ignores scope — its key is a domain",
         ("cert_expiry", "worker", {"api.example.com": "7"}),
         {"api.example.com": "7"}),
        ("a scope naming a service with no rows fires nothing",
         ("cpu", "absent", services), {}),
    ]

    ok = True
    for name, args, want in cases:
        got = alerts.scoped(*args)
        if got == want:
            print(f"ok    scope: {name}")
        else:
            print(f"FAIL  scope: {name}\n        got  {got}\n        want {want}")
            ok = False
    return ok


def main() -> int:
    alerts = load_alerts()
    results = [check_sql(alerts), check_messages(alerts), check_scope(alerts)]
    print("\n" + ("all checks passed" if all(results) else "CHECKS FAILED"))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
