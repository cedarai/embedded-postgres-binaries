#!/bin/bash
set -euo pipefail

PGBUILD=${PGBUILD:-"$(cd "$(dirname "$0")"/../pg-build && pwd)"}
PGBIN="$PGBUILD/bin"
DATADIR=${DATADIR:-/tmp/pgdata}
LOGFILE=${LOGFILE:-/tmp/pg.log}

echo "Using PGBUILD=$PGBUILD"

if [ ! -x "$PGBIN/initdb" ]; then
  echo "initdb not found at $PGBIN/initdb" >&2
  exit 1
fi

rm -rf "$DATADIR"
mkdir -p "$DATADIR"

"$PGBIN/initdb" -D "$DATADIR"
"$PGBIN/pg_ctl" -D "$DATADIR" -l "$LOGFILE" start

cleanup() {
  set +e
  "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$PGBIN/pg_isready"

echo "Postgres server version:"
"$PGBIN/psql" -d postgres -X -A -t -c "select version();"

echo "Testing pgvector extension..."
"$PGBIN/psql" -d postgres -v ON_ERROR_STOP=1 -X -c "create extension if not exists vector;"
"$PGBIN/psql" -d postgres -X -A -t -c "select '[-1,2,3]'::vector as v;"
"$PGBIN/psql" -d postgres -X -A -t -c "select '[-1,2,3]'::vector <-> '[0,0,0]'::vector as l2;"

if ls "$PGBUILD/share/postgresql/extension" | grep -q postgis; then
  echo "Testing PostGIS extension..."
  "$PGBIN/psql" -d postgres -v ON_ERROR_STOP=1 -X -c "create extension if not exists postgis;"
  "$PGBIN/psql" -d postgres -X -A -t -c "select PostGIS_Full_Version();" >/dev/null
fi

if ls "$PGBUILD/share/postgresql/extension" | grep -q pgrouting; then
  echo "Testing pgRouting extension..."
  "$PGBIN/psql" -d postgres -v ON_ERROR_STOP=1 -X -c "create extension if not exists pgrouting;"
fi

echo "Smoke test OK"
