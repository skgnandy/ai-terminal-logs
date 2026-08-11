#!/usr/bin/env python3
"""Catch VRL scope errors before Vector rejects the config.

    tools/vrl-lint.py /path/to/vector.toml

VRL scopes a variable to the block it is assigned in, so this:

    if sev == null {
      http = parse_regex(raw, ...) ?? null
    }
    if http != null { ... }          # error[E701]: undefined variable

is rejected in full — one bad reference and the collector keeps running the
previous config while every check upstream reports healthy.

This exists because the only real validator is `vector validate`, which needs
the Vector binary and therefore the target machine. Shipping a config that only
the machine can check has broken collection three times (E620, E651, E701), each
time discovered after install. A read of a variable that is not live in any
enclosing scope is decidable from the text alone, so it does not need Vector.

Deliberately narrow: it checks exactly this one thing. A linter that tried to
type-check VRL would be wrong often enough to be ignored, and an ignored linter
catches nothing.
"""

import re
import sys
import tomllib

# Names VRL provides. Not exhaustive — only what this config uses, plus the
# obvious neighbours, because an unknown function name here is a false positive
# and false positives are how a check gets switched off.
BUILTINS = {
    "if", "else", "null", "true", "false", "abort", "return",
    "parse_regex", "parse_json", "parse_timestamp", "parse_key_value",
    "to_int", "to_float", "to_string", "to_bool", "format_timestamp",
    "string", "upcase", "downcase", "contains", "includes", "replace",
    "starts_with", "ends_with", "strip_whitespace", "slice", "split",
    "length", "now", "del", "exists", "set", "get", "push", "merge",
    "is_timestamp", "is_null", "is_string", "match", "compact", "join",
    "encode_json", "decode_json", "truncate", "sha2", "md5", "uuid_v4",
    "float", "int", "array", "object", "timestamp",
}

IDENT = re.compile(r"(?<![.\w!])([A-Za-z_][A-Za-z0-9_]*)")
ASSIGN = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:,\s*\w+\s*)?=(?!=)")


def strip_noise(line):
    """Remove comments, strings and regex literals — their contents are not code."""
    line = re.sub(r"#.*$", "", line)
    line = re.sub(r"r'(?:[^'\\]|\\.)*'", "''", line)
    line = re.sub(r'r"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)*'", "''", line)
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    return line


def lint(source):
    """Return a list of (line number, name, text) for out-of-scope reads."""
    problems = []
    scopes = [set()]

    for lineno, raw in enumerate(source.splitlines(), 1):
        code = strip_noise(raw)
        if not code.strip():
            continue

        # A variable assigned on this line is not yet live for its own reads on
        # the right-hand side, but VRL allows self-reference (x = x + 1) only if
        # x already exists, so check reads first, then declare.
        assigned = ASSIGN.match(code)
        declares = assigned.group(1) if assigned else None

        live = set().union(*scopes)
        # Deduplicated per line: a variable used twice in one condition is one
        # mistake, and reporting it twice makes a short report look like a long
        # one.
        seen = set()
        for name in IDENT.findall(code):
            if name in BUILTINS or name in live or name in seen:
                continue
            # The left-hand side of its own assignment is a declaration.
            if name == declares:
                continue
            seen.add(name)
            problems.append((lineno, name, raw.strip()))

        if declares:
            scopes[-1].add(declares)

        # Brace bookkeeping last, so a variable assigned on the same line as an
        # opening brace belongs to the outer scope, which is where VRL puts it.
        for ch in code:
            if ch == "{":
                scopes.append(set())
            elif ch == "}" and len(scopes) > 1:
                scopes.pop()

    return problems


def main():
    path = sys.argv[1]
    if path.endswith(".toml"):
        config = tomllib.load(open(path, "rb"))
        sources = {
            f"transforms.{name}": t["source"]
            for name, t in (config.get("transforms") or {}).items()
            if isinstance(t, dict) and isinstance(t.get("source"), str)
        }
    else:
        sources = {path: open(path, encoding="utf-8").read()}

    failed = False
    for name, source in sources.items():
        problems = lint(source)
        if not problems:
            print(f"ok    {name}: no out-of-scope reads")
            continue
        failed = True
        for lineno, var, text in problems:
            print(f"FAIL  {name}:{lineno}: '{var}' is not live here")
            print(f"          {text}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
