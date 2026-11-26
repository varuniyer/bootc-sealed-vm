#!/bin/sh
set -eu

# Reads the plaintext password from stdin and writes its SCRAM-SHA-256 hash to stdout. The server
# listens only on a socket in the operator-tools container's /tmp, a tmpfs, and ends with the script.

PGDATA=$(mktemp -d)
export PGDATA PGHOST=/tmp
trap 'pg_ctl -m immediate stop >/dev/null 2>&1 || true; rm -r "$PGDATA"' EXIT
initdb -A trust >/dev/null 2>&1
pg_ctl -o "-k $PGHOST -h ''" start -w >/dev/null
psql -tAqX -v ON_ERROR_STOP=1 -f "${0%/*}/hash.sql"
