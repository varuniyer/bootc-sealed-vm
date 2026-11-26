#!/usr/bin/env bash
set -euo pipefail

# AWS signs a token that proves the caller is the build instance's role, and Tailscale's federated
# credential exchanges it for a short-lived API token that may only change the policy file. Each
# token reaches curl on stdin, so none appears in argv.
source "$PWD/build.env"
tailscale_policy_client_id=$(aws ssm get-parameter --name "${BUILD_PARAMETERS}tailscale-policy-client-id" --query Parameter.Value --output text)
tailscale_policy_audience=$(aws ssm get-parameter --name "${BUILD_PARAMETERS}tailscale-policy-audience" --query Parameter.Value --output text)
# Tailscale validates the policy and runs its tests before it replaces the tailnet's.
aws sts get-web-identity-token --audience "$tailscale_policy_audience" --signing-algorithm RS256 --query WebIdentityToken --output text | tr -d '\n' | \
    curl -sS --fail-with-body --data-urlencode "client_id=$tailscale_policy_client_id" --data-urlencode jwt@- https://api.tailscale.com/api/v2/oauth/token-exchange | \
    jq -er '.access_token // empty | "Authorization: Bearer " + .' | \
    curl -sS --fail-with-body -H @- -H 'Content-Type: application/json' --data-binary @tailscale/policy.json https://api.tailscale.com/api/v2/tailnet/-/acl >/dev/null
