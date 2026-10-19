#!/usr/bin/env bash
# scripts/release_version.sh takes a good tag's version and refuses a bad tag,
# a commit off main and one with no passing run, with `gh` replaced by a stub
# that answers as GitHub would.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/release_version.sh"
stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT

# The stub answers `gh api .../compare/...` with $COMPARE and `gh run list`
# with $RUN, each already filtered as the script's --jq would leave it.
cat >"$stub/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  api) echo "$COMPARE" ;;
  run) echo "$RUN" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$stub/gh"

failures=0
check() { # NAME EXPECTED_STATUS EXPECTED_STDOUT ENV... -- ARGS...
  local name=$1 want_status=$2 want_out=$3
  shift 3
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  local out status
  out=$(env PATH="$stub:$PATH" GITHUB_SHA=abc GITHUB_REPOSITORY=o/r "${envs[@]}" \
    "$script" "$@" 2>/dev/null)
  status=$?
  if [ "$status" = "$want_status" ] && [ "$out" = "$want_out" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: status $status, output '$out' (wanted $want_status, '$want_out')"
    failures=$((failures + 1))
  fi
}

check "a branch build has no release version" 0 "" GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main --
check "a good tag gives its version" 0 "RELEASE_VERSION=1.2.3" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3 --
check "a zero component is a version" 0 "RELEASE_VERSION=0.10.0" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v0.10.0 --
for bad in 1.2.3 v1.2 v1.2.3.4 v01.2.3 v1.2.3-rc.1 v1.2.3+build vX.Y.Z "v1.2.3 " legacy-v0.1.2; do
  check "refuses the tag '$bad'" 1 "" GITHUB_REF_TYPE=tag "GITHUB_REF_NAME=$bad" --
done
check "a green commit of main is released" 0 "RELEASE_VERSION=1.2.3" \
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3 COMPARE=identical RUN=42 -- --from-green-main
check "an older green commit of main is released" 0 "RELEASE_VERSION=1.2.3" \
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3 COMPARE=behind RUN=42 -- --from-green-main
check "refuses a commit not on main" 1 "" \
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3 COMPARE=ahead RUN=42 -- --from-green-main
check "refuses a commit that diverged from main" 1 "" \
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3 COMPARE=diverged RUN=42 -- --from-green-main
check "refuses a commit of main with no passing run" 1 "" \
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3 COMPARE=identical RUN= -- --from-green-main
check "refuses a bad tag before asking GitHub" 1 "" \
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2 COMPARE=identical RUN=42 -- --from-green-main

[ "$failures" = 0 ] || exit 1
