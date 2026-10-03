#!/bin/sh
# A release carries every command the README runs, executable.
# Usage: scripts/release_executables_check.sh RELEASE_DIR
#
# The overlay scripts are how anyone actually uses the release. A release that
# built but shipped one missing or not executable is a broken download.
# foreground_boot_check.py runs bin/at_mcp and bin/at_mcp-accounts; at_mcp-connect
# and at_mcp-stdio are started by an agent client, so they are checked here.
set -eu
rel=$1
missing=0
for f in at_mcp at_mcp-accounts at_mcp-connect at_mcp-stdio; do
  if [ ! -f "$rel/bin/$f" ]; then
    echo "missing: bin/$f"; missing=1
  elif [ ! -x "$rel/bin/$f" ]; then
    echo "not executable: bin/$f"; missing=1
  fi
done
[ "$missing" = 0 ] || exit 1
ls -l "$rel/bin"
