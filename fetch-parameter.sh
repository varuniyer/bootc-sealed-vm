#!/usr/bin/env bash
set -euo pipefail

# Prints the value provision.sh set in Parameter Store under the key $1. An empty key lists the keys.
vm_parameters=/bootc-vm/
if [ -n "$1" ]; then
    request=$(jq -nc --arg name "$vm_parameters$1" '{Name: $name, WithDecryption: true}')
    /opt/scripts/aws-api.sh ssm AmazonSSM.GetParameter "$request" | jq -j .Parameter.Value
    exit
fi
# Parameter Store lists at most ten parameters per call.
pagination='{}'
while [ -n "$pagination" ]; do
    request=$(jq -c --arg vm_parameters "$vm_parameters" '{Path: $vm_parameters} + .' <<< "$pagination")
    page=$(/opt/scripts/aws-api.sh ssm AmazonSSM.GetParametersByPath "$request")
    jq -r --arg vm_parameters "$vm_parameters" '.Parameters[].Name | ltrimstr($vm_parameters)' <<< "$page"
    pagination=$(jq -c '.NextToken // empty | {NextToken: .}' <<< "$page")
done
