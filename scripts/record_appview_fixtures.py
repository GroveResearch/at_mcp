"""Record the AppView responses test/at_mcp/field_coverage_test.exs reads.

    python3 scripts/record_appview_fixtures.py OUT_DIR ACTOR GATED_POST_URI

ACTOR is a public account with reposts, a pinned post, replies and varied
embeds in its recent posts; GATED_POST_URI is a post of it with a threadgate.
Neither is written down here: the fixtures should not lead back to who they
were recorded from.

The script reads public, unauthenticated AppView responses, keeps the fewest
feed items and replies that together carry every field path, and replaces
every value that could identify a record or a person. Keys, value types and
the shape of each string (an AT URI stays an AT URI with a TID record key, a
CID stays a CID of the same length, a timestamp stays a timestamp) are kept.

Every string is replaced unless its key is in KEEP, a short list of keys whose
values are enumerations from the lexicon rather than content. A key the
lexicon adds later is therefore scrubbed until someone decides otherwise.
Integers are replaced too, except facet byte offsets, which must still index
the (replaced) text. Replacements are deterministic within one run (the same
DID maps to the same fake DID everywhere, so references still line up) and
salted with a random value that is not saved, so they cannot be reversed by
hashing candidates.
"""
import datetime, hashlib, json, os, re, secrets, sys, urllib.parse, urllib.request

out, ACTOR, GATED = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
APPVIEW = "https://public.api.bsky.app/xrpc/"
SALT = secrets.token_bytes(32)

# Every timestamp moves by the same random offset, so order and spacing hold.
SHIFT = datetime.timedelta(seconds=int.from_bytes(SALT[:4], "big") % (400 * 86400) + 86400)

# Keys whose string values are lexicon enumerations or type names, not content.
KEEP = {
    "$type", "val", "langs", "mimeType", "purpose", "presentation", "contentMode",
    "verifiedStatus", "trustedVerifierStatus", "allowIncoming", "allowSubscriptions",
    "allowGroupInvites", "showButtonTo", "status",
}

# Integers that must keep their value: byte offsets into a post's text.
KEEP_INT = {"byteStart", "byteEnd"}

B32 = "abcdefghijklmnopqrstuvwxyz234567"
TID = "234567abcdefghijklmnopqrstuvwxyz"
DID_RE = re.compile(r"did:(?:plc|web):[A-Za-z0-9._%:-]+")
TIME_RE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)$")
AT_RE = re.compile(r"^at://([^/]+)(?:/([^/]+)(?:/([^/]+))?)?$")


def digest(kind, value):
    return hashlib.sha256(SALT + kind.encode() + b"\0" + value.encode()).digest()


def letters(kind, value, alphabet, n):
    d = digest(kind, value)
    while len(d) < n:
        d += hashlib.sha256(d).digest()
    return "".join(alphabet[b % len(alphabet)] for b in d[:n])


def did(value):
    return "did:plc:" + letters("did", value, B32, 24)


def tid(value):
    return letters("tid", value, TID, 13)


def cid(value):
    # Same multibase prefix and length, so it reads as the same kind of CID.
    return value[:4] + letters("cid", value, B32, len(value) - 4)


def at_uri(value):
    m = AT_RE.match(value)
    if not m:
        return "at://" + did(value)
    repo, collection, rkey = m.groups()
    parts = [did(repo) if repo.startswith("did:") else handle(repo)]
    if collection:
        parts.append(collection)
    if rkey:
        parts.append("self" if rkey == "self" else tid(rkey))
    return "at://" + "/".join(parts)


def handle(value):
    return letters("handle", value, B32, 10) + ".example.test"


def timestamp(value):
    when = datetime.datetime.fromisoformat(value.replace("Z", "+00:00")) + SHIFT
    text = when.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    fraction = re.search(r"\.\d+", value)
    return text + (fraction.group(0) if fraction else "") + "Z"


def scrub(v, key=None):
    if isinstance(v, dict):
        return {k: scrub(x, k) for k, x in v.items()}
    if isinstance(v, list):
        return [scrub(x, key) for x in v]
    if isinstance(v, bool) or v is None or isinstance(v, float):
        return v
    if isinstance(v, int):
        # Counts and sizes can single an account out; keep the type, and zero.
        if key in KEEP_INT or v == 0:
            return v
        return int.from_bytes(digest("int", f"{key}:{v}")[:2], "big") % 997 + 1
    if key in KEEP:
        return v
    if v.startswith("at://"):
        return at_uri(v)
    if v.startswith("did:"):
        return DID_RE.sub(lambda m: did(m.group(0)), v)
    if key in ("cid", "$link") or re.fullmatch(r"baf[a-z2-7]{20,}", v):
        return cid(v)
    if TIME_RE.match(v):
        return timestamp(v)
    if v.startswith("http"):
        return "https://example.test/" + letters("url", v, B32, 12)
    if key == "handle" or (key or "").endswith("Handle"):
        return handle(v)
    # Anything else is content: x repeated to the same byte length, so a
    # facet's byte range still falls inside the text it indexes.
    return "x" * len(v.encode())


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


def cover(items):
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


def fetch(method, **params):
    url = APPVIEW + method + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


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
