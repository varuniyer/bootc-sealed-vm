# containers/policy.json names the registry whose images the VM accepts, and every AWS resource
# is in that registry's region.
AWS_DEFAULT_REGION=$(jq -er '.transports.docker | keys[0] | capture("\\.ecr\\.(?<region>[^.]+)\\.").region' "$PWD/containers/policy.json")
export AWS_DEFAULT_REGION
