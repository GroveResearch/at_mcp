#!/usr/bin/env bash
# End-to-end round trips: every write tool against upstream's reference PDS
# and AppView, running on this machine (test/e2e, docs/operations.md "End-to-end
# round trips").
#
#   scripts/e2e.sh [mix test arguments]
#
# Builds `@atproto/dev-env` from the atproto commit the vendored lexicons come
# from (once; kept under AT_MCP_E2E_DIR, default _build/e2e), starts a private
# Postgres and Redis unless DB_POSTGRES_URL and REDIS_HOST name running ones,
# runs `mix test --only e2e`, which starts the network and stops it when the
# suite ends, and stops what it started. Everything listens on localhost; the
# network reaches nothing beyond it.
#
# Needs git, Node 22.19 or later, pnpm 11.11.0, and, without DB_POSTGRES_URL
# and REDIS_HOST, initdb, pg_ctl and redis-server on PATH.
set -euo pipefail

# The atproto commit test/fixtures/lexicons were copied from.
ATPROTO_COMMIT=9f66a7e54b030700c03eda0bdbf35ffe756f4cd8

root=$(cd "$(dirname "$0")/.." && pwd)
work=${AT_MCP_E2E_DIR:-$root/_build/e2e}
atproto=$work/atproto
mkdir -p "$work"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "e2e: $1 is not on PATH; $2" >&2
    exit 1
  }
}

need git "it fetches the atproto checkout"
need node "Node 22.19 or later runs the network"
need pnpm "pnpm 11.11.0 builds the atproto checkout"

# atproto's build (its translation catalogs) needs Node 22.19 or later.
node -e '
  const [major, minor] = process.versions.node.split(".").map(Number)
  if (major < 22 || (major === 22 && minor < 19)) {
    console.error(`e2e: Node ${process.versions.node} is too old; atproto needs 22.19 or later`)
    process.exit(1)
  }'

# --- the reference network's code, built once per commit ---

if [ ! -f "$atproto/.built-$ATPROTO_COMMIT" ]; then
  echo "e2e: building atproto at $ATPROTO_COMMIT in $atproto"
  rm -rf "$atproto"
  mkdir -p "$atproto"
  git -C "$atproto" init -q
  git -C "$atproto" fetch -q --depth 1 https://github.com/bluesky-social/atproto.git "$ATPROTO_COMMIT"
  git -C "$atproto" checkout -q FETCH_HEAD
  # Puppeteer's browser is for atproto's own browser tests, not the network.
  # pnpm's package store is kept beside the checkout, not in $HOME.
  (cd "$atproto" &&
    PUPPETEER_SKIP_DOWNLOAD=1 pnpm install --frozen-lockfile --store-dir "$work/pnpm-store" &&
    pnpm build)
  touch "$atproto/.built-$ATPROTO_COMMIT"
fi

export AT_MCP_E2E_DEV_ENV=$atproto/packages/dev-env

# --- Postgres and Redis, unless given ---

started=()
run=
cleanup() {
  for service in ${started[@]+"${started[@]}"}; do
    case $service in
      postgres) pg_ctl -D "$run/pg" -m fast stop >/dev/null 2>&1 || true ;;
      redis) redis-cli -h 127.0.0.1 -p "$redis_port" shutdown nosave >/dev/null 2>&1 || true ;;
    esac
  done
  [ -n "${run:-}" ] && rm -rf "$run"
  return 0
}
trap cleanup EXIT

free_port() {
  node -e '
    const s = require("net").createServer()
    s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close() })'
}

# A Postgres or Redis given must be on this machine: the suite reaches nothing
# beyond it.
loopback='^(postgres(ql)?://([^@/]*@)?)?(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?(/.*)?$'
for given in "${DB_POSTGRES_URL:-}" "${REDIS_HOST:-}"; do
  [ -z "$given" ] || [[ $given =~ $loopback ]] || { echo "e2e: $given is not on localhost" >&2; exit 1; }
done

# Everything a run writes (the network's repositories and blobs, Postgres and
# Redis when started here) goes in one directory, removed when it ends.
run=$(mktemp -d "$work/run.XXXXXX")
mkdir -p "$run/tmp"
export TMPDIR=$run/tmp

if [ -z "${DB_POSTGRES_URL:-}" ]; then
  need initdb "or set DB_POSTGRES_URL to a running Postgres"
  need pg_ctl "or set DB_POSTGRES_URL to a running Postgres"
  pg_port=$(free_port)
  # Postgres on macOS refuses to start without a locale in the environment.
  LC_ALL=C initdb -D "$run/pg" -U pg --auth=trust --encoding=UTF8 --locale=C >"$run/initdb.log"
  # Recorded first, so a start that fails part way is still stopped.
  started+=(postgres)
  LC_ALL=C pg_ctl -D "$run/pg" -l "$run/pg.log" -w \
    -o "-p $pg_port -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" start >/dev/null
  export DB_POSTGRES_URL="postgresql://pg@127.0.0.1:$pg_port/postgres"
fi

if [ -z "${REDIS_HOST:-}" ]; then
  need redis-server "or set REDIS_HOST to a running Redis"
  need redis-cli "or set REDIS_HOST to a running Redis"
  redis_port=$(free_port)
  started+=(redis)
  redis-server --port "$redis_port" --bind 127.0.0.1 --save "" --appendonly no \
    --dir "$run" --daemonize yes --pidfile "$run/redis.pid" --logfile "$run/redis.log"
  export REDIS_HOST="127.0.0.1:$redis_port"
fi

# --- the suite ---

cd "$root"
MIX_ENV=test mix test --only e2e "$@"
