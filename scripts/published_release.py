"""Fetch release N, the release an upgrade check starts from.
Usage: python3 scripts/published_release.py PLATFORM DEST

Run in GitHub Actions, with GH_TOKEN, GITHUB_REPOSITORY and GITHUB_SHA set;
PLATFORM is linux-x86_64 or macos-arm64.

N is the newest published release (not a draft, not a prerelease) that
carries PLATFORM's tarball, so a release whose build for this platform failed
is never chosen, and whose tag is not the commit under test (GITHUB_SHA): an
upgrade from a build to itself proves nothing. The tarball's name is derived
from the tag, so releases tagged by version (v0.2.0) and the earlier ones
tagged by build (v0.1.0-<short sha>) are both found. CI downloads release N
with GitHub authentication, checks its SHA-256, and unpacks it under DEST;
the release directory is printed on standard output, everything else goes to
standard error. An AtMcp release also names its commit in BUILD, and an N built
from the commit under test is refused.
"""

import json
import os
import pathlib
import re
import subprocess
import sys


VERSION_TAG = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")


def layout(tag, platform):
    """The tarball's name and the directory it holds; None for a tarball holding `at_mcp`."""
    if VERSION_TAG.fullmatch(tag):
        return "at_mcp-%s-%s.tar.gz" % (tag[1:], platform), "at_mcp-" + tag[1:]
    # Historical build-tagged releases used an unversioned top directory.
    # Retain their unpack layout while they remain possible upgrade inputs.
    return "at_mcp-%s-%s.tar.gz" % (tag[1:], platform), None


def tarball_name(tag, platform):
    return layout(tag, platform)[0]


def unpack(tarball, dest, tag, platform):
    """Unpack under DEST and return the release directory."""
    directory = layout(tag, platform)[1]
    if directory is None:
        target = dest / ("at_mcp-" + tag)
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
            and any(a["name"] == tarball_name(r["tag_name"], platform) for a in r["assets"])
        ),
        key=lambda r: r["published_at"],
        reverse=True,
    )
    tag = next((r["tag_name"] for r in candidates if tag_commit(repo, r["tag_name"]) != sha), None)
    if tag is None:
        sys.exit("no published release carries %s and differs from the commit under test" % platform)
    name = tarball_name(tag, platform)
    print("release N: %s" % tag, file=sys.stderr)
    dest.mkdir(parents=True, exist_ok=True)
    subprocess.run(["gh", "release", "download", tag, "--repo", repo, "--pattern", name + "*", "--dir", str(dest)],
                   check=True, stdout=sys.stderr)
    subprocess.run(["shasum", "-a", "256", "-c", name + ".sha256"], cwd=dest, check=True, stdout=sys.stderr)
    old = unpack(dest / name, dest, tag, platform)
    built = commit_of(old)
    if built is not None and sha.startswith(built):
        sys.exit("release N (%s) was built from %s, the commit under test: an upgrade to itself proves nothing" % (tag, built))
    print(old)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    fetch(os.environ["GITHUB_REPOSITORY"], sys.argv[1], pathlib.Path(sys.argv[2]).resolve(), os.environ["GITHUB_SHA"])
