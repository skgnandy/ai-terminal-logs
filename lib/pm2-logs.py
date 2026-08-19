#!/usr/bin/env python3
"""Where PM2 actually writes its logs, and which service each file belongs to.

Reads one or more `pm2 jlist` documents on stdin — one per PM2_HOME, simply
concatenated — and prints, depending on the mode:

    globs   include patterns for the collector, one per line
    map     JSON object of log-path stem -> service name, for the parser
    files   <mtime>\t<size>\t<service>\t<path> for every log file that
            exists, newest first

Guessing ~/.pm2/logs is not enough, and the failure it causes is silent.
`out_file` / `error_file` in an ecosystem file put a service's log anywhere on
disk. A machine configured that way is indistinguishable from a machine with no
PM2 at all: the collector reads the directory it was told to read, finds nothing
in it but pm2-logrotate's own two logs, reports no error of any kind, and every
selected service stores zero rows forever. Metrics keep working the whole time —
they come from `pm2 jlist`, not from files — so the app shows healthy processes
next to empty charts, which is the worst shape a failure can take.

So the log locations come from PM2 itself, and the service name comes from PM2
rather than from the filename whenever the two disagree.
"""

import glob
import json
import os
import re
import sys

# Identical to the parser's regex in lib/vector-config.sh. The trailing group is
# pm2-logrotate's stamp; without it a rotated file resolves to its own filename.
STREAM_RE = re.compile(r"-(out|error)(-\d+)?(__[^/]*)?\.log$")

DEFAULT_DIRS = ["/root/.pm2/logs"] + sorted(glob.glob("/home/*/.pm2/logs"))


def jlist_docs(text):
    """Every JSON array in `text`, tolerating anything printed around them.

    PM2 prints update notices and, under some node managers, deprecation
    warnings on the same stream as `jlist`. json.load() on the whole buffer
    fails on those, and a crash here would take the log locations down with it.
    """
    decoder = json.JSONDecoder()
    i = 0
    while True:
        i = text.find("[", i)
        if i < 0:
            return
        try:
            doc, end = decoder.raw_decode(text, i)
        except ValueError:
            i += 1
            continue
        i = end
        if isinstance(doc, list):
            yield doc


def entries():
    """(service name, log path) for every stream PM2 says it is writing."""
    out = []
    for doc in jlist_docs(sys.stdin.read()):
        for proc in doc:
            if not isinstance(proc, dict):
                continue
            name = proc.get("name")
            env = proc.get("pm2_env") or {}
            if not name:
                continue
            for key in ("pm_out_log_path", "pm_err_log_path", "pm_log_path"):
                path = proc.get(key) or env.get(key)
                # /dev/null is how a process says "do not keep this stream".
                if not path or not isinstance(path, str) or path == "/dev/null":
                    continue
                # No normpath: PM2 reports absolute POSIX paths, and normalising
                # them is the one thing that could turn a correct path wrong.
                out.append((name, path))
    return out


def stem(path):
    """What the parser derives from a path before it looks up a name."""
    return STREAM_RE.sub("", path)


def glob_for(path):
    """A pattern covering this stream and its rotations, and nothing else.

    Deliberately not the whole directory. A custom log path is routinely
    somewhere shared — /var/log is the common one — and watching `*.log` there
    would put syslog, auth.log and every other unrelated file into the
    collector's watch set to be read and then thrown away by the filter.
    """
    base = stem(path)
    if base == path and path.endswith(".log"):
        base = path[: -len(".log")]
    return base + "*.log"


def build():
    """globs, name map and the default directories, from one pass over PM2."""
    default_dirs = [d for d in DEFAULT_DIRS if os.path.isdir(d)]
    globs = ["%s/*.log" % d for d in default_dirs]
    name_map = {}

    for name, path in entries():
        directory = os.path.dirname(path)
        if directory not in DEFAULT_DIRS:
            pattern = glob_for(path)
            if pattern not in globs:
                globs.append(pattern)
        # Only where the filename does not already say it. On a default install
        # it always does, so the map stays empty and the parser behaves exactly
        # as it did before this existed.
        if STREAM_RE.sub("", os.path.basename(path)) != name:
            name_map[stem(path)] = name

    return globs, name_map


def service_of(path, name_map):
    # glob returns paths with the platform's separator, and the map keys come
    # from pm2. They agree on the machines this runs on; the normalisation is so
    # the behaviour can be exercised off one, and is a no-op on POSIX.
    if os.sep != "/":
        path = path.replace(os.sep, "/")
    mapped = name_map.get(stem(path))
    if mapped:
        return mapped
    base = STREAM_RE.sub("", os.path.basename(path))
    if base.endswith(".log"):
        base = base[: -len(".log")]
    return base


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "globs"
    globs, name_map = build()

    if mode == "globs":
        for pattern in globs:
            print(pattern)
        return

    if mode == "map":
        print(json.dumps(name_map, sort_keys=True))
        return

    if mode == "files":
        seen = set()
        rows = []
        for pattern in globs:
            for path in glob.glob(pattern):
                if path in seen or not os.path.isfile(path):
                    continue
                seen.add(path)
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                rows.append((st.st_mtime, st.st_size, service_of(path, name_map), path))
        rows.sort(reverse=True)
        for mtime, size, service, path in rows:
            print("%d\t%d\t%s\t%s" % (int(mtime), size, service, path))
        return

    print("unknown mode: %s" % mode, file=sys.stderr)
    raise SystemExit(2)


main()
