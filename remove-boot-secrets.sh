#!/usr/bin/env bash
set -euo pipefail

# Removes the secrets the VM reads only at boot from Parameter Store: pending-secrets, which
# boot-configuration.sh stores on /var, and the first boot's Tailscale auth key and PostgreSQL hash.
# PostgreSQL answers once some boot finished, so provision.sh reboots the VM while secrets are pending.
source "$PWD/build.env"
source "$PWD/region.sh"
boot_secret_names=$(aws ssm get-parameters --names "${VM_PARAMETER_PATH}pending-secrets" "${VM_PARAMETER_PATH}tailscale-auth-key" "${VM_PARAMETER_PATH}postgresql-experiments-password-hash" --query 'Parameters[].Name' --output text)
[ -n "$boot_secret_names" ] || exit 0
# provision.sh sets the tailnet DNS name among the VM's parameters.
tailnet_dns_name=$(aws ssm get-parameter --name "${VM_PARAMETER_PATH}tailnet-dns-name" --query Parameter.Value --output text)
until pg_isready -q -h "$REPOSITORY.$tailnet_dns_name"; do sleep 10; done
aws ssm delete-parameters --names $boot_secret_names >/dev/null
