#!/usr/bin/env bash
set -euo pipefail

# boot-configuration.sh writes the hash file.
postgresql_experiments_password_hash_file=/run/boot-postgresql/postgresql-experiments-password-hash
if [ -f "$postgresql_experiments_password_hash_file" ]; then
    /opt/scripts/bootstrap.sh < "$postgresql_experiments_password_hash_file"
fi
