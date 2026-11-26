#!/usr/bin/env bash
# Builds the Spaces helper (spaces_helper/) into one file the release ships,
# priv/spaces_helper/at_mcp-spaces.mjs, with its license notices beside it.
# Needs Node 22 or later and npm. A release built without it runs with Spaces
# off (AtMcp.Spaces.Helper).
set -euo pipefail
cd "$(dirname "$0")/../spaces_helper"
npm ci --no-audit --no-fund --loglevel=error
npm run -s check
npm test
npm run -s build
ls -l ../priv/spaces_helper/
