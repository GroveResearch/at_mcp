"""Record the AppView responses test/at_mcp/field_coverage_test.exs reads.

    python3 scripts/record_appview_fixtures.py test/fixtures/appview

Reads public, unauthenticated responses from the Bluesky AppView about the
official @bsky.app account and one of its threadgated posts, keeps the fewest
feed items and replies that together carry every field path, and replaces
identities, text and URLs. Keys and value types are kept exactly, and text keeps
its byte length so facet ranges still fall inside it: the fixtures carry the
AppView's shape and none of its people. Re-record when the lexicon grows.
"""
import json, os, re, sys, hashlib, urllib.request, urllib.parse

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
APPVIEW = "https://public.api.bsky.app/xrpc/"
ACTOR = "bsky.app"
# A post of that account with a threadgate (it hides one reply).
GATED = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l6oveex3ii2l"


def fetch(method, **params):
    url = APPVIEW + method + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


dids, handles = {}, {}
DID_RE = re.compile(r"did:(?:plc|web):[a-zA-Z0-9._%-]+")


def did(d):
    if d not in dids:
        dids[d] = f"did:plc:fixture{len(dids) + 1:04d}"
    return dids[d]


def handle(h):
    if h not in handles:
        handles[h] = f"account{len(handles) + 1}.example.test"
    return handles[h]


TEXT_KEYS = {"text", "description", "alt", "title", "name", "displayName", "tag"}


def scrub(v, key=None):
    if isinstance(v, dict):
        return {k: scrub(x, k) for k, x in v.items()}
    if isinstance(v, list):
        return [scrub(x, key) for x in v]
    if not isinstance(v, str):
        return v
    if key == "$type" or key in {"cid", "createdAt", "indexedAt", "updatedAt", "cts", "exp",
                                 "val", "verifiedStatus", "trustedVerifierStatus",
                                 "allowIncoming", "allowSubscriptions", "purpose",
                                 "presentation", "contentMode", "reason", "mimeType", "$link"}:
        return v
    if key == "handle" or (key or "").endswith("Handle"):
        return handle(v)
    if key in ("did", "src", "issuer", "subject") and v.startswith("did:"):
        return did(v)
    if key in TEXT_KEYS or (key or "").endswith("DisplayName"):
        # Same byte length, ASCII, so facet byte ranges still fall inside the text.
        return re.sub(r"[^\n]", "x", "x" * len(v.encode()))[: len(v.encode())]
    if v.startswith("at://"):
        return DID_RE.sub(lambda m: did(m.group(0)), v)
    if v.startswith("http"):
        h = hashlib.sha1(v.encode()).hexdigest()[:10]
        return f"https://example.test/{h}"
    if v.startswith("did:"):
        return did(v)
    return v


def leaves(v, path=""):
    if isinstance(v, dict):
        s = set()
        for k, x in v.items():
            s |= leaves(x, f"{path}.{k}" if path else k)
        return s
    if isinstance(v, list):
        s = set()
        for x in v:
            s |= leaves(x, path + "[]")
        return s or {path + "[]"}
    return {path}


def cover(items, limit=None):
    """Greedy: the fewest items whose leaf paths cover every path in items."""
    want = set().union(*(leaves(i) for i in items))
    chosen, have = [], set()
    while have != want:
        best = max(items, key=lambda i: len(leaves(i) - have))
        if not leaves(best) - have:
            break
        chosen.append(best)
        have |= leaves(best)
    return chosen


def write(name, value):
    with open(os.path.join(out, name), "w") as f:
        json.dump(scrub(value), f, indent=2, ensure_ascii=False)
        f.write("\n")


feed = fetch("app.bsky.feed.getAuthorFeed", actor=ACTOR, limit=100, includePins="true",
             filter="posts_with_replies")["feed"]
write("feed.json", {"feed": cover(feed)})

thread = fetch("app.bsky.feed.getPostThread", uri=GATED, depth=1, parentHeight=2)
thread["thread"]["replies"] = cover(thread["thread"].get("replies", []))[:4]
write("thread.json", thread)

write("profile.json", fetch("app.bsky.actor.getProfile", actor=ACTOR))
write("likes.json", fetch("app.bsky.feed.getLikes", uri=GATED, limit=2))
write("feeds.json", fetch("app.bsky.feed.getSuggestedFeeds", limit=3))
