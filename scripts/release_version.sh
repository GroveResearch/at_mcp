#!/usr/bin/env bash
# The version a CI build is, from the ref it runs for.
#
# Usage: scripts/release_version.sh [--from-green-main]
#
# For a tag (GITHUB_REF_TYPE=tag), prints `RELEASE_VERSION=X.Y.Z` for
# "$GITHUB_ENV", taken from the tag `vX.Y.Z`, which mix.exs then builds as.
# Any other tag is refused: a release is cut by pushing `vX.Y.Z` and nothing
# else, so a typo must not publish. For anything else it prints nothing, and
# the build is mix.exs's development version.
#
# With --from-green-main, a tag is refused unless its commit (GITHUB_SHA) is
# on main and a run of the `check` workflow passed for it in the merge queue
# or on main, so only a commit that passed everything is released. That asks
# GitHub (gh, with GH_TOKEN and GITHUB_REPOSITORY; the token needs
# `actions: read`).
set -euo pipefail

if [ "${GITHUB_REF_TYPE:-}" != tag ]; then
  exit 0
fi

tag=${GITHUB_REF_NAME:?GITHUB_REF_NAME is not set}
if ! [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "the tag $tag is not a release tag: a release is v followed by X.Y.Z, such as v1.2.3" >&2
  exit 1
fi
version=${tag#v}

if [ "${1:-}" = --from-green-main ]; then
  sha=${GITHUB_SHA:?GITHUB_SHA is not set}
  repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}

  # `behind` or `identical`: the commit is main or an ancestor of it.
  status=$(gh api "repos/$repo/compare/main...$sha" --jq .status)
  case "$status" in
    identical | behind) ;;
    *)
      echo "$tag is on $sha, which is not on main (compared with main: $status); tag a commit of main" >&2
      exit 1
      ;;
  esac

  run=$(gh run list --repo "$repo" --workflow check --commit "$sha" --status success \
    --limit 50 --json databaseId,event,headBranch \
    --jq '[.[] | select(.event == "merge_group" or (.event == "push" and .headBranch == "main"))][0].databaseId // empty')
  if [ -z "$run" ]; then
    echo "no run of check passed for $sha in the merge queue or on main; tag a commit of main once its run has passed" >&2
    exit 1
  fi
  echo "$tag: $sha is on main and passed check in run $run" >&2
fi

echo "RELEASE_VERSION=$version"
