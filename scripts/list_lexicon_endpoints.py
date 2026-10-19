"""List the lexicon methods and records test/at_mcp/endpoint_coverage_test.exs checks.

    python3 scripts/list_lexicon_endpoints.py ATPROTO_CHECKOUT [TOWN_LEXICONS] \
        > test/fixtures/lexicon_endpoints.txt

ATPROTO_CHECKOUT is a checkout of bluesky-social/atproto. Its
`packages/bsky/lexicons` holds the `app.bsky.*` and `chat.bsky.*` lexicons the
AppView is built from, committed there for offline builds, and its `lexicons`
holds `com.atproto.*` and `tools.ozone.*`. TOWN_LEXICONS, if given, is a
directory of `town.delve.*` lexicons; only the methods and records with no
`app.bsky.*` counterpart are listed from it, because the rest are the same
endpoints under the other namespace (see `AtMcp.Network`).

Each line is `NSID TYPE`, where TYPE is query, procedure, subscription or
record, sorted. The header records where the list came from.
"""
import json, os, subprocess, sys

KINDS = {"query", "procedure", "subscription", "record"}


def walk(root):
    for d, _, files in os.walk(root):
        for f in files:
            if not f.endswith(".json"):
                continue
            try:
                doc = json.load(open(os.path.join(d, f)))
            except (OSError, ValueError):
                continue
            kind = doc.get("defs", {}).get("main", {}).get("type")
            if kind in KINDS:
                yield doc["id"], kind


def commit(path):
    try:
        return subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


atproto = sys.argv[1]
entries = {}
for sub in ("packages/bsky/lexicons", "lexicons"):
    for nsid, kind in walk(os.path.join(atproto, sub)):
        entries[nsid] = kind

print(f"# bluesky-social/atproto {commit(atproto)}: packages/bsky/lexicons, lexicons")

if len(sys.argv) > 2:
    town = sys.argv[2]
    print(f"# town.delve lexicons {commit(town)}: those with no app.bsky counterpart")
    for nsid, kind in walk(town):
        if nsid.startswith("town.delve.") and \
                "app.bsky." + nsid[len("town.delve."):] not in entries:
            entries[nsid] = kind

for nsid in sorted(entries):
    print(nsid, entries[nsid])
