#!/usr/bin/env bash
set -euo pipefail

# Recovery mode serves only the management API, so Stalwart handles no mail until the plan is
# applied. Its admin exists only for this run, and the server stalwart.service starts holds no
# admin credential.
admin_secret=$(head -c 32 /dev/urandom | base64)
STALWART_RECOVERY_MODE=1 STALWART_RECOVERY_MODE_PORT=8008 STALWART_RECOVERY_ADMIN="admin:$admin_secret" \
    /usr/bin/stalwart --config /etc/stalwart/config.json &
server_pid=$!
trap 'kill "$server_pid"; wait "$server_pid" || true' EXIT

until curl -so /dev/null http://127.0.0.1:8008/; do sleep 1; done
# Creating the ACME provider registers its account with Let's Encrypt, so an unreachable CA fails
# the first boot's apply until it answers.
until STALWART_URL=http://127.0.0.1:8008 STALWART_USER=admin STALWART_PASSWORD="$admin_secret" \
    /usr/bin/stalwart-cli apply --file /run/stalwart/plan.ndjson; do sleep 30; done
