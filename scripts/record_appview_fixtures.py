"""Record the AppView responses test/at_mcp/field_coverage_test.exs reads.

    python3 scripts/record_appview_fixtures.py OUT_DIR ACTOR GATED_POST_URI
    python3 scripts/record_appview_fixtures.py OUT_DIR --lists QUERY
    python3 scripts/record_appview_fixtures.py OUT_DIR --discovery

ACTOR is a public account with reposts, a pinned post, replies and varied
embeds in its recent posts; GATED_POST_URI is a post of it with a threadgate.
Neither is written down here: the fixtures should not lead back to who they
were recorded from.

The script reads public, unauthenticated AppView responses, keeps the fewest
feed items and replies that together carry every field path, and replaces
every value that could identify a record or a person. Keys, value types and
the shape of each string (an AT URI stays an AT URI with a TID record key, a
CID stays a CID of the same length, a timestamp stays a timestamp) are kept.

With --lists, it records lists and starter packs instead: a search for
QUERY's starter packs, the pack among them recommending the most feeds, its
creator's packs and its list, and the curation lists of the first creator in
the results who has any.

With --discovery, it records what the app's Explore page reads: one suggested
feed as `feed.getFeedGenerator` describes it, trends, trending topics, and
suggested starter packs.

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

out = sys.argv[1]
LISTS = sys.argv[2] == "--lists"
DISCOVERY = sys.argv[2] == "--discovery"
if LISTS:
    QUERY = sys.argv[3]
elif not DISCOVERY:
    ACTOR, GATED = sys.argv[2], sys.argv[3]
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


def record_lists():
    packs = fetch("app.bsky.graph.searchStarterPacksV2", q=QUERY, limit=25)["starterPacks"]
    write("starter_packs.json", {"starterPacks": cover(packs)})
    pack = max(packs, key=lambda p: len(p.get("feeds") or []))
    write("starter_pack.json", fetch("app.bsky.graph.getStarterPack", starterPack=pack["uri"]))
    actor = pack["creator"]["did"]
    write("actor_starter_packs.json",
          fetch("app.bsky.graph.getActorStarterPacks", actor=actor, limit=10))
    write("list.json", fetch("app.bsky.graph.getList", list=pack["list"]["uri"], limit=3))
    for creator in dict.fromkeys(p["creator"]["did"] for p in packs):
        lists = fetch("app.bsky.graph.getLists", actor=creator, limit=50)["lists"]
        if lists:
            write("lists.json", {"lists": cover(lists)})
            break


def record_posts():
    feed = fetch("app.bsky.feed.getAuthorFeed", actor=ACTOR, limit=100, includePins="true",
                 filter="posts_with_replies")["feed"]
    write("feed.json", {"feed": cover(feed)})

    thread = fetch("app.bsky.feed.getPostThread", uri=GATED, depth=1, parentHeight=2)
    thread["thread"]["replies"] = cover(thread["thread"].get("replies", []))[:4]
    write("thread.json", thread)

    write("profile.json", fetch("app.bsky.actor.getProfile", actor=ACTOR))
    write("likes.json", fetch("app.bsky.feed.getLikes", uri=GATED, limit=2))
    write("feeds.json", fetch("app.bsky.feed.getSuggestedFeeds", limit=3))


def record_discovery():
    feeds = fetch("app.bsky.unspecced.getSuggestedFeeds", limit=25)["feeds"]
    # The feed whose view carries the most fields, so the fewest are missing.
    feed = max(feeds, key=lambda f: len(leaves(f)))
    write("feed_generator.json", fetch("app.bsky.feed.getFeedGenerator", feed=feed["uri"]))
    trends = fetch("app.bsky.unspecced.getTrends", limit=25)
    write("trends.json", {"trends": cover(trends["trends"])})
    topics = fetch("app.bsky.unspecced.getTrendingTopics", limit=25)
    write("trending_topics.json",
          {"topics": cover(topics["topics"]), "suggested": cover(topics["suggested"])})
    packs = fetch("app.bsky.unspecced.getSuggestedStarterPacks", limit=25)["starterPacks"]
    write("suggested_starter_packs.json", {"starterPacks": cover(packs)})


if LISTS:
    record_lists()
elif DISCOVERY:
    record_discovery()
else:
    record_posts()
