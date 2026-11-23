#!/usr/bin/env bash
set -euo pipefail

# ECR's registry password lasts twelve hours, so each update fetch starts with a new one, which the
# VM's instance role obtains. bootc reads the password from this file.
( umask 077; /opt/scripts/aws-api.sh api.ecr AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken '{}' | jq -c '.authorizationData[0] | {auths: {(.proxyEndpoint | ltrimstr("https://")): {auth: .authorizationToken}}}' > /etc/ostree/auth.json )
