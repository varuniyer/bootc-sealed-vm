#!/usr/bin/env bash
set -euo pipefail

# Removes the secrets the VM reads only at boot from Parameter Store: pending-secrets, which
# boot-configuration.sh stores on /var, and the first boot's Tailscale auth key and PostgreSQL hash.
# PostgreSQL answers once some boot finished, so provision.sh reboots the VM while secrets are pending.
source "$PWD/build.env"
source "$PWD/region.sh"
names=$(aws ssm get-parameters --names "${VM_PARAMETERS}pending-secrets" "${VM_PARAMETERS}tailscale-auth-key" "${VM_PARAMETERS}postgresql-experiments-hash" --query 'Parameters[].Name' --output text)
[ -n "$names" ] || exit 0
# provision.sh sets the tailnet among the VM's parameters.
tailnet=$(aws ssm get-parameter --name "${VM_PARAMETERS}tailnet" --query Parameter.Value --output text)
until pg_isready -q -h "$REPOSITORY.$tailnet"; do sleep 10; done
aws ssm delete-parameters --names $names >/dev/null
