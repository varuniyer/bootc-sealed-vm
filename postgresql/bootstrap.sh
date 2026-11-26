#!/usr/bin/env bash
set -euo pipefail

# $PGDATA appears only at the final rename, so boot-configuration.sh's first-boot test stays true after a failed attempt.
staging_directory=$PGDATA.staging
rm -rf "$staging_directory"
initdb -D "$staging_directory"
pg_ctl -D "$staging_directory" -o "-c config_file=/etc/postgresql/postgresql.conf" -w start
psql -d postgres -v ON_ERROR_STOP=1 -qX -f /usr/share/boot-postgresql/bootstrap.sql
pg_ctl -D "$staging_directory" -w stop
mv -T "$staging_directory" "$PGDATA"
