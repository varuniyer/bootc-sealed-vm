#!/usr/bin/env bash
set -euo pipefail

# Calls the action $2 of the AWS service whose endpoint prefix is $1 with the JSON request $3, as the
# VM's instance role, and prints the response. The role's credentials reach curl through its
# configuration on stdin, so none appears in argv.
imds_url=http://169.254.169.254/latest
imds_token=$(curl -sSf -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' "$imds_url/api/token")
fetch_metadata() { printf 'header = "X-aws-ec2-metadata-token: %s"\n' "$imds_token" | curl -sSf -K - "$imds_url/meta-data/$1"; }
region=$(fetch_metadata placement/region)
role_name=$(fetch_metadata iam/security-credentials/)
fetch_metadata "iam/security-credentials/$role_name" | jq -r '"user = \(.AccessKeyId + ":" + .SecretAccessKey | @json)", "header = \("X-Amz-Security-Token: " + .Token | @json)"' | \
    curl -sS --fail-with-body -K - --aws-sigv4 "aws:amz:$region:${1##*.}" -H "X-Amz-Target: $2" -H 'Content-Type: application/x-amz-json-1.1' --data "$3" "https://$1.$region.amazonaws.com/"
