"""Fetch release N, the release an upgrade check starts from.
Usage: python3 scripts/published_release.py PLATFORM DEST

Run in GitHub Actions, with GH_TOKEN, GITHUB_REPOSITORY and GITHUB_SHA set;
PLATFORM is linux-x86_64 or macos-arm64.

N is the newest published release (not a draft, not a prerelease) that
carries PLATFORM's tarball, so a release whose build for this platform failed
is never chosen, and whose tag is not the commit under test (GITHUB_SHA): an
upgrade from a build to itself proves nothing. The tarball's name is derived
from the tag, so releases tagged by version (v0.2.0) and the earlier ones
tagged by build (v0.1.0-<short sha>) are both found. CI retrieves this historical baseline with GitHub authentication (unlike the
public newcomer curl path), checks its SHA-256, and unpacks it under DEST;
the release directory is printed on standard output, everything else goes to
standard error. A AtMcp release also names its commit in BUILD, and an N built
from the commit under test is refused.
"""

import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.request


VERSION_TAG = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")

# What differs between AtMcp, Dwell and Haven: the tarball's name, what it
# holds, and whether the release records the commit it was built from.


def layout(tag, platform, app="at_mcp"):
    """The tarball's name and the directory it holds; None for a tarball holding `at_mcp`."""
    if VERSION_TAG.fullmatch(tag):
        return "%s-%s-%s.tar.gz" % (app, tag[1:], platform), app + "-" + tag[1:]
    # Historical build-tagged releases used an unversioned top directory.
    # Retain their unpack layout while they remain possible upgrade inputs.
    return "%s-%s-%s.tar.gz" % (app, tag[1:], platform), None


def tarball_name(tag, platform, app="at_mcp"):
    return layout(tag, platform, app)[0]


def unpack(tarball, dest, tag, platform, app="at_mcp"):
    """Unpack under DEST and return the release directory."""
    directory = layout(tag, platform, app)[1]
    if directory is None:
        target = dest / (app + "-" + tag)
        target.mkdir(parents=True)
        strip = ["--strip-components=1"]
    else:
        target = dest / directory
        strip = []
    subprocess.run(["tar", "--no-same-owner", *strip, "-xzf", str(tarball), "-C", str(target if strip else dest)],
                   check=True, stdout=sys.stderr)
    if not target.is_dir():
        sys.exit("%s does not hold %s" % (tarball.name, target.name))
    return target


def commit_of(release):
    """The short commit the release was built from, from its BUILD file."""
    return (release / "BUILD").read_text().strip().removesuffix("-dirty").rsplit("-", 1)[-1]


def gh(*args):
    return subprocess.run(["gh", *args], check=True, text=True, capture_output=True).stdout


def tag_commit(repo, tag):
    return gh("api", "repos/%s/commits/%s" % (repo, tag), "--jq", ".sha").strip()


# A fresh public snapshot has no prior at_mcp release or private Git history.
# The explicit legacy prerelease carries the genuine old executable with added
# notices. Its Git tag points at the new root, so tag identity cannot identify
# its code. Reviewed archive digests and its exact historical BUILD do that.
# Keep this path only while Kite -> at_mcp remains a supported first upgrade;
# any ordinary eligible release takes precedence, and its failures never fall
# back here. Missing baseline assets fail the gate rather than skip it.
LEGACY_MANIFEST = pathlib.Path(__file__).with_name("legacy_baseline.json")


def fetch_baseline(repo, platform, dest, sha):
    baseline = json.loads(LEGACY_MANIFEST.read_text())
    asset = baseline["assets"][platform]
    name, digest = asset["name"], asset["sha256"]
    if pathlib.Path(name).name != name or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("invalid legacy baseline manifest")
    build = baseline["build"]
    if sha.startswith(build.rsplit("-", 1)[-1]):
        raise ValueError("legacy baseline is the candidate itself")
    url = "https://github.com/%s/releases/download/%s/%s" % (repo, baseline["tag"], name)
    # No GitHub token or private-repository access is needed by this path.
    with urllib.request.urlopen(url) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != digest:
        raise ValueError("legacy baseline checksum mismatch")
    dest.mkdir(parents=True, exist_ok=True)
    archive = dest / name
    archive.write_bytes(content)
    old = unpack(archive, dest, "v0.1.2", platform, "kite")
    if (old / "BUILD").read_text().strip() != build:
        raise ValueError("legacy baseline BUILD mismatch")
    print("release N: verified legacy Kite baseline " + build, file=sys.stderr)
    return old


def fetch(repo, platform, dest, sha):
    # The API lists releases newest first; one page of 100 reaches back far
    # enough for the newest one that carries a given platform.
    releases = json.loads(gh("api", "repos/%s/releases?per_page=100" % repo))
    candidates = sorted(
        (
            r
            for r in releases
            if not r["draft"]
            and not r["prerelease"]
            and any(a["name"] == tarball_name(r["tag_name"], platform, app)
                    for a in r["assets"] for app in ("at_mcp", "kite"))
        ),
        key=lambda r: r["published_at"],
        reverse=True,
    )
    tag = next((r["tag_name"] for r in candidates if tag_commit(repo, r["tag_name"]) != sha), None)
    if tag is None:
        print(fetch_baseline(repo, platform, dest, sha))
        return
    release = next(r for r in candidates if r["tag_name"] == tag)
    # Keep the real pre-rename release as the upgrade input until an at_mcp
    # release exists. The asset, not a guessed version threshold, names it.
    app = next(app for app in ("at_mcp", "kite")
               if any(a["name"] == tarball_name(tag, platform, app) for a in release["assets"]))
    name = tarball_name(tag, platform, app)
    print("release N: %s" % tag, file=sys.stderr)
    dest.mkdir(parents=True, exist_ok=True)
    subprocess.run(["gh", "release", "download", tag, "--repo", repo, "--pattern", name + "*", "--dir", str(dest)],
                   check=True, stdout=sys.stderr)
    subprocess.run(["shasum", "-a", "256", "-c", name + ".sha256"], cwd=dest, check=True, stdout=sys.stderr)
    old = unpack(dest / name, dest, tag, platform, app)
    built = commit_of(old)
    if built is not None and sha.startswith(built):
        sys.exit("release N (%s) was built from %s, the commit under test: an upgrade to itself proves nothing" % (tag, built))
    print(old)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    fetch(os.environ["GITHUB_REPOSITORY"], sys.argv[1], pathlib.Path(sys.argv[2]).resolve(), os.environ["GITHUB_SHA"])
