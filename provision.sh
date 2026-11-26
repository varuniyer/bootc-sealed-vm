#!/usr/bin/env bash
set -euo pipefail

VM_INSTANCE_TYPE=m9g.medium
VM_BOOT_VOLUME_SIZE=150
BUILD_INSTANCE_TYPE=m9g.large
BUILD_FEDORA_RELEASE=45
DOMAIN=varuniyer.net
ACME_EMAIL=acme@varuniyer.net
WEBSITE_ALIAS_DOMAINS="varuniyer.info, varuniyer.me, www.varuniyer.net, www.varuniyer.info, www.varuniyer.me"
MAIL_USER=varun
MAIL_ALIAS_DOMAINS="varuniyer.info"
TAILNET_DNS_NAME=tailbc280c.ts.net

# operator-tools.sh runs this script in the operator-tools image, which supplies every tool it uses.
# $1 is the website's checkout, which operator-tools.sh mounts read-only at /website.
[ -n "${OPERATOR_TOOLS:-}" ] || \
    {
        WEBSITE_CHECKOUT=$(realpath -e "${1:?Pass the path to the website checkout.}")
        export WEBSITE_CHECKOUT
        exec "$PWD/operator-tools.sh" "./${0##*/}"
    }

source "$PWD/build.env"
source "$PWD/region.sh"
source "$PWD/read-secret.sh"
source "$PWD/fetch-this-machine.sh"
source "$PWD/desec.sh"
source "$PWD/tailscale/wireguard-port.env"

vm_name=bootc-vm
# Only the first boot reads the Tailscale auth key and the PostgreSQL hash, so only the run that
# creates the VM makes the key and asks for the PostgreSQL password.
vm_instance_id=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$vm_name" Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -z "$vm_instance_id" ]; then
    read_secret 'PostgreSQL experiments password' POSTGRESQL_EXPERIMENTS_PASSWORD
fi
# A run against the existing VM reuses every value that still holds, so a rerun with unchanged
# settings and secrets changes nothing. Parameters remain when the VM they were set for is deleted,
# and a new VM starts without them.
existing_vm_parameters=$(aws ssm get-parameters-by-path --path "$VM_PARAMETER_PATH" --with-decryption --query 'Parameters[].{key: Name, value: Value}' | \
    jq -c --arg path "$VM_PARAMETER_PATH" 'map({(.key | ltrimstr($path)): .value}) | add // {}')
if [ -z "$vm_instance_id" ] && [ "$existing_vm_parameters" != '{}' ]; then
    jq -r --arg path "$VM_PARAMETER_PATH" 'keys[] | $path + .' <<< "$existing_vm_parameters" | xargs -n 10 aws ssm delete-parameters --names >/dev/null
    existing_vm_parameters='{}'
fi
read_existing_vm_parameter() { printf '%s' "$existing_vm_parameters" | jq -r --arg key "$1" '.[$key] // empty'; }
# pending-secrets carries each secret the VM lacks the current value of, and boot-configuration.sh
# stores them on /var. It starts from any pending secrets a stopped run left in Parameter Store, so
# that run's secrets still reach the VM.
pending_secrets=$(read_existing_vm_parameter pending-secrets)
[ -n "$pending_secrets" ] || \
    pending_secrets='{}'
# add_pending_secret prints the pending secrets with the secret on its stdin added under key $1. The
# pending secrets reach jq through /dev/fd, so both stay outside argv.
add_pending_secret() { jq -Rsc --arg key "$1" --slurpfile pending_secrets <(printf '%s' "$pending_secrets") '$pending_secrets[0] + {($key): .}'; }
read_secret "Mail password for $MAIL_USER@$DOMAIN" MAIL_PASSWORD
read_secret "Relay password of the Forward Email alias $MAIL_USER@$DOMAIN" RELAY_PASSWORD
create_desec_token provision

# Stalwart stores a bcrypt hash as given, so only the hash after htpasswd's "user:" prefix reaches
# the VM. bcrypt salts every hash, so the run hashes the password only when the existing VM's Stalwart
# rejects it. The JMAP session endpoint answers only a signed-in client.
if [ -z "$vm_instance_id" ] || ! printf '%s:%s' "$MAIL_USER" "$MAIL_PASSWORD" | jq -Rrs '"user = " + @json' | \
        curl -sfL --max-time 30 -o /dev/null -K - "https://$REPOSITORY.$TAILNET_DNS_NAME/.well-known/jmap"; then
    pending_secrets=$(printf '%s' "$MAIL_PASSWORD" | htpasswd -niBC 12 "$MAIL_USER" | cut -d: -f2- | tr -d '\n' | add_pending_secret mail-password-hash)
fi

# /var's TPM policy admits each PCR 11 policy the PCR key signs. KMS makes each key and keeps its
# private half, so a build can sign only while it runs.
create_key_if_missing() {
    local key
    aws kms describe-key --key-id "$1" >/dev/null 2>&1 || \
        {
            key=$(aws kms create-key \
                --key-spec "$2" \
                --key-usage SIGN_VERIFY \
                --description "$3" \
                --query KeyMetadata.KeyId --output text)
            aws kms create-alias \
                --alias-name "$1" \
                --target-key-id "$key"
        }
}
create_key_if_missing "$SECUREBOOT_KEY" RSA_2048 'Signs systemd-boot and each UKI for Secure Boot'
create_key_if_missing "$PCR_KEY" RSA_2048 'Signs the PCR 11 policy of each UKI'
create_key_if_missing "$IMAGE_KEY" ECC_NIST_P256 'Signs each published image'
fetch_public_key() { aws kms get-public-key --key-id "$1" --query PublicKey --output text | base64 -d | openssl pkey -pubin -inform DER; }
image_public_key=$(fetch_public_key "$IMAGE_KEY")

# Each build instance boots the newest Fedora cloud AMI of this release, which the launch template
# reads from this parameter. EC2 checks the parameter when the stack creates the launch template.
# Fedora publishes its AMIs from this account.
build_instance_ami_id=$(aws ec2 describe-images --owners 125523088429 --filters "Name=name,Values=Fedora-Cloud-Base-AmazonEC2.aarch64-$BUILD_FEDORA_RELEASE-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
existing_build_instance_ami_id=$(aws ssm get-parameters --names "${BUILD_PARAMETER_PATH}build-instance-ami-id" --query 'Parameters[].Value' --output text)
[ "$build_instance_ami_id" = "$existing_build_instance_ami_id" ] || \
    aws ssm put-parameter --name "${BUILD_PARAMETER_PATH}build-instance-ami-id" --type String --data-type aws:ec2:image --overwrite --value "$build_instance_ami_id" >/dev/null

# reserve-address.sh allocates the address, which remains after the VM and the stack, so the A
# records keep resolving to reprovisioned VMs and the address keeps its reverse DNS record.
address_name=bootc-ip
address_allocation_id=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$address_name" --query 'Addresses[].AllocationId' --output text)
if [ -z "$address_allocation_id" ]; then
    echo "No Elastic IP address is named $address_name. Run reserve-address.sh first (see README)." >&2
    exit 1
fi

# infrastructure.yaml holds the other AWS resources that remain when the VM is deleted, and a deploy
# changes only the resources whose definitions changed. The VM's network interface is in the
# default subnet of the first zone that offers the instance type.
availability_zones=$(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters "Name=instance-type,Values=$VM_INSTANCE_TYPE" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' ,)
subnet=$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true "Name=availability-zone,Values=$availability_zones" --query 'sort_by(Subnets, &AvailabilityZone)[0].SubnetId' --output text)
stack=bootc
aws cloudformation deploy --stack-name "$stack" --template-file infrastructure.yaml --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset --parameter-overrides \
    "Repository=$REPOSITORY" "WebsiteRepository=$WEBSITE_REPOSITORY" "SecurebootKey=$SECUREBOOT_KEY" "PcrKey=$PCR_KEY" "ImageKey=$IMAGE_KEY" "RedhatCredentialsSecret=$REDHAT_CREDENTIALS_SECRET" "EntitlementCertificateSecret=$ENTITLEMENT_CERTIFICATE_SECRET" "BuildParameterPath=$BUILD_PARAMETER_PATH" "VmParameterPath=$VM_PARAMETER_PATH" "BuildInstanceType=$BUILD_INSTANCE_TYPE" "BuildInstanceName=$BUILD_INSTANCE_NAME" "BuildLog=$BUILD_LOG" "Subnet=$subnet" "AddressAllocationId=$address_allocation_id" "WireguardPort=$WIREGUARD_PORT"
fetch_stack_output() { aws cloudformation describe-stacks --stack-name "$stack" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
list_build_parameter() { aws ssm get-parameters --names "$BUILD_PARAMETER_PATH$1" --query 'Parameters[].Name' --output text; }

# Each build instance applies tailscale/policy.json through a Tailscale federated credential, which
# trusts only the tokens AWS signs for its role. The client ID and audience are public, so both are
# String parameters. A credential that a failed run left without its parameter is deleted first.
federated_credential_description='bootc-build instance role'
tailscale_policy_client_id_listed=$(list_build_parameter tailscale-policy-client-id)
this_machine=$(fetch_this_machine)
operator_tag_missing=$(printf '%s' "$this_machine" | jq .operator_tag_missing)
if [ -z "$tailscale_policy_client_id_listed" ] || [ "$operator_tag_missing" = true ] || [ -z "$vm_instance_id" ]; then
    read_secret 'Tailscale API access token' TAILSCALE_API_TOKEN
fi
tailscale_api_base=https://api.tailscale.com/api/v2
# The API access token reaches curl through a /dev/fd header file.
call_tailscale_api() { curl -sS --fail-with-body -H @<(printf 'Authorization: Bearer %s' "$TAILSCALE_API_TOKEN") "$@"; }
[ -n "$tailscale_policy_client_id_listed" ] || \
    {
        stale_federated_credential_ids=$(call_tailscale_api "$tailscale_api_base/tailnet/-/keys?all=true" | \
            jq -r --arg description "$federated_credential_description" '.keys[] | select(.keyType == "federated" and .description == $description) | .id')
        for stale_federated_credential_id in $stale_federated_credential_ids; do
            call_tailscale_api -X DELETE "$tailscale_api_base/tailnet/-/keys/$stale_federated_credential_id" >/dev/null
        done
        # AWS signs the tokens only once the account's outbound identity federation is on.
        issuer=$(aws iam get-outbound-web-identity-federation-info --query IssuerIdentifier --output text 2>/dev/null) || \
            issuer=$(aws iam enable-outbound-web-identity-federation --query IssuerIdentifier --output text)
        build_role_arn=$(fetch_stack_output BuildRoleArn)
        federated_credential=$(jq -n --arg description "$federated_credential_description" --arg issuer "$issuer" --arg subject "$build_role_arn" '{keyType: "federated", $description, scopes: ["policy_file", "devices:core:read", "devices:posture_attributes"], $issuer, $subject}' | \
            call_tailscale_api -H 'Content-Type: application/json' --data @- "$tailscale_api_base/tailnet/-/keys")
        tailscale_policy_audience=$(printf '%s' "$federated_credential" | jq -er '.audience // "api.tailscale.com/\(.id)"')
        tailscale_policy_client_id=$(printf '%s' "$federated_credential" | jq -er .id)
        aws ssm put-parameter --name "${BUILD_PARAMETER_PATH}tailscale-policy-audience" --type String --overwrite --value "$tailscale_policy_audience" >/dev/null
        aws ssm put-parameter --name "${BUILD_PARAMETER_PATH}tailscale-policy-client-id" --type String --value "$tailscale_policy_client_id" >/dev/null
    }

# publish-tlsa.sh runs here and reaches the VM's tailnet port 25 as tag:operator. A device can take
# the tag only once the tailnet's policy names it in tagOwners, and the build instances apply the
# policy only from the first build on, so this run applies it first.
if [ "$operator_tag_missing" = true ]; then
    call_tailscale_api -H 'Content-Type: application/json' --data-binary @tailscale/policy.json "$tailscale_api_base/tailnet/-/acl" >/dev/null
    device_id=$(printf '%s' "$this_machine" | jq -r .id)
    printf '%s' "$this_machine" | jq -c '{tags: (.tags + ["tag:operator"])}' | \
        call_tailscale_api -H 'Content-Type: application/json' --data @- "$tailscale_api_base/device/$device_id/tags" >/dev/null
fi

fetch_vm_ami() { aws ec2 describe-images --owners self --filters "Name=name,Values=$VM_AMI_NAME" --query "Images[].$1" --output text; }
# The firmware matches the certificate itself, so it only has to carry the Secure Boot key's public
# half, and openssl signs it with a key this run makes and discards. A VM AMI built under an
# earlier certificate would give a new VM firmware that rejects the new signatures.
secureboot_certificate_listed=$(list_build_parameter secureboot-certificate)
[ -n "$secureboot_certificate_listed" ] || \
    {
        secureboot_public_key=$(fetch_public_key "$SECUREBOOT_KEY")
        secureboot_certificate=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | \
            openssl x509 -new -force_pubkey <(printf '%s' "$secureboot_public_key") -key /dev/stdin -subj "/CN=$REPOSITORY Secure Boot" -days 36500 2>/dev/null)
        stale_vm_ami_id=$(fetch_vm_ami ImageId)
        [ -z "$stale_vm_ami_id" ] || \
            aws ec2 deregister-image --image-id "$stale_vm_ami_id" --delete-associated-snapshots >/dev/null
        aws ssm put-parameter --name "${BUILD_PARAMETER_PATH}secureboot-certificate" --type String --value "$secureboot_certificate" >/dev/null
    }

# Each build clones main from this repository's and the website's CodeCommit repositories. The first
# run pushes main from each checkout, and each push starts a build. A newer build ends an older one,
# and a run that finds this repository's branch and no VM AMI starts one here.
codecommit_git=(git -c credential.helper='!aws codecommit credential-helper $@' -c credential.UseHttpPath=true)
aws codecommit get-branch --repository-name "$WEBSITE_REPOSITORY" --branch-name main >/dev/null 2>&1 || \
    {
        website_clone_url=$(fetch_stack_output WebsiteCloneUrl)
        "${codecommit_git[@]}" -C /website push "$website_clone_url" main
    }
vm_ami_state=$(fetch_vm_ami State)
existing_main_branch=$(aws codecommit get-branch --repository-name "$REPOSITORY" --branch-name main --query branch.branchName --output text 2>/dev/null) || \
    {
        clone_url=$(fetch_stack_output CloneUrl)
        "${codecommit_git[@]}" push "$clone_url" main
    }
[ -z "$existing_main_branch" ] || [ -n "$vm_ami_state" ] || \
    {
        build_state_machine_arn=$(fetch_stack_output BuildStateMachineArn)
        aws stepfunctions start-execution --state-machine-arn "$build_state_machine_arn" >/dev/null
    }
# EC2 creates an instance only from an available AMI. A build that ends without one has failed.
until [ "$vm_ami_state" = available ]; do
    sleep 60
    vm_ami_state=$(fetch_vm_ami State)
    build_instances=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$BUILD_INSTANCE_NAME" Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId' --output text)
    if [ -z "$vm_ami_state" ] && [ -z "$build_instances" ]; then
        account_id=$(aws sts get-caller-identity --query Account --output text)
        echo "The build ended without a VM AMI. Read its log in s3://bootc-build-logs-$account_id/$BUILD_LOG." >&2
        exit 1
    fi
done

# Stalwart logs in to Forward Email's relay with this password. The VM cannot show which password it
# holds, so Parameter Store records the SHA-256 of the one it was sent, as it records the public
# halves of the keys.
relay_password_sha256=$(printf '%s' "$RELAY_PASSWORD" | sha256sum | head -c 64)
existing_relay_password_sha256=$(read_existing_vm_parameter relay-password-sha256)
[ "$relay_password_sha256" = "$existing_relay_password_sha256" ] || \
    pending_secrets=$(printf '%s' "$RELAY_PASSWORD" | add_pending_secret relay-password)

# Stalwart signs Web Push notifications with this Web Push key, and clients' push subscriptions name
# its public half, so the VM keeps its key while Parameter Store records the public half. openssl
# writes each new key only to stdout.
web_push_public_key=$(read_existing_vm_parameter web-push-public-key)
[ -n "$web_push_public_key" ] || \
    {
        web_push_key=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null)
        web_push_public_key=$(printf '%s' "$web_push_key" | openssl pkey -pubout)
        pending_secrets=$(printf '%s' "$web_push_key" | add_pending_secret web-push-key)
    }

# Senders fetch the policy again whenever the _mta-sts TXT id changes, so the id hashes the policy.
printf -v mta_sts_policy 'version: STSv1\nmode: enforce\nmx: mail.%s\nmax_age: 604800\n' "$DOMAIN"
mta_sts_id=$(printf '%s' "$mta_sts_policy" | sha256sum | head -c 20)

address=$(aws ec2 describe-addresses --allocation-ids "$address_allocation_id" --query 'Addresses[0].PublicIp' --output text)

# queue_rrset queues an RRset for its zone's one PATCH (see write_rrsets): a name, a type, and the
# records as a JSON array. queue_zone_rrset takes the name's zone first, from a caller that holds it.
declare -A zone_rrsets
queue_zone_rrset() {
    local subname
    subname=$(strip_zone "$2" "$1")
    zone_rrsets[$1]+=$(format_rrset "$subname" "$3" "$4")$'\n'
}
queue_rrset() {
    local zone
    zone=$(fetch_zone "$1")
    queue_zone_rrset "$zone" "$@"
}
# An apex TXT set also holds other services' verification values, so only its SPF value changes.
queue_spf() {
    local zone subname records
    zone=$(fetch_zone "$1")
    subname=$(strip_zone "$1" "$zone")
    records=$(call_desec "$desec_api/domains/$zone/rrsets/?subname=$subname&type=TXT" | \
        jq -c --arg spf "\"$2\"" '[(.[0].records // [])[] | select(startswith("\"v=spf1") | not)] + [$spf]')
    queue_zone_rrset "$zone" "$1" TXT "$records"
}

# Stalwart signs each message the mailbox sends with this DKIM key before the relay takes it. Receivers
# check the signature against the key's public half in DNS, which Parameter Store records as it does
# the Web Push key's.
dkim_selector=bootc
dkim_public_key=$(read_existing_vm_parameter dkim-public-key)
[ -n "$dkim_public_key" ] || \
    {
        dkim_key=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)
        dkim_public_key=$(printf '%s' "$dkim_key" | openssl pkey -pubout -outform DER | base64 -w0)
        pending_secrets=$(printf '%s' "$dkim_key" | add_pending_secret dkim-key)
    }
# One TXT string holds at most 255 characters, and the record exceeds that.
dkim_records=$(jq -nc --arg record "v=DKIM1; k=rsa; p=$dkim_public_key" '[[$record | scan(".{1,255}") | "\"\(.)\""] | join(" ")]')
queue_rrset "$dkim_selector._domainkey.$DOMAIN" TXT "$dkim_records"
# Forward Email's servers deliver the domain's mail, so the SPF value names them alone.
queue_spf "$DOMAIN" 'v=spf1 include:spf.forwardemail.net -all'
mail_alias_domains=(${MAIL_ALIAS_DOMAINS//,/ })
mail_domains=("$DOMAIN" "${mail_alias_domains[@]}")
for mail_domain in "${mail_domains[@]}"; do
    queue_rrset "$mail_domain" MX "[\"10 mail.$DOMAIN.\"]"
done
for mail_alias_domain in "${mail_alias_domains[@]}"; do
    queue_spf "$mail_alias_domain" 'v=spf1 -all'
done

# The A records point every served name at the address before Caddy's and Stalwart's first
# certificate requests. The CAA records admit only Let's Encrypt, through the HTTP-01 and
# TLS-ALPN-01 challenges that Caddy and Stalwart answer.
website_alias_domains=(${WEBSITE_ALIAS_DOMAINS//,/ })
for name in "$DOMAIN" "mail.$DOMAIN" "mta-sts.$DOMAIN" "${website_alias_domains[@]}"; do
    queue_rrset "$name" A "[\"$address\"]"
    queue_rrset "$name" CAA '["0 issue \"letsencrypt.org; validationmethods=http-01,tls-alpn-01\""]'
done
# A website alias domain that receives no mail refuses it with a null MX and forbids sending as it.
for name in "${website_alias_domains[@]}"; do
    [[ " ${mail_domains[*]} " == *" $name "* ]] && continue
    queue_rrset "$name" MX '["0 ."]'
    queue_spf "$name" 'v=spf1 -all'
done
queue_rrset "_mta-sts.$DOMAIN" TXT "[\"\\\"v=STSv1; id=$mta_sts_id\\\"\"]"
# A new VM's Stalwart generates a new key, so the TLSA record that pinned the old one goes away until
# publish-tlsa.sh pins the new one. An existing VM keeps its key across runs.
if [ -z "$vm_instance_id" ]; then
    queue_rrset "_25._tcp.mail.$DOMAIN" TLSA '[]'
fi
for zone in "${!zone_rrsets[@]}"; do
    rrsets=$(printf '%s' "${zone_rrsets[$zone]}" | jq -sc .)
    write_rrsets "$zone" "$rrsets"
done

# Every boot reads the settings, and the public halves name the keys the VM holds. A parameter is
# written only when it holds another value.
parameters_changed=
set_vm_parameter() {
    jq -e --arg key "$1" --rawfile value <(printf '%s' "$3") '.[$key] == $value' <<< "$existing_vm_parameters" >/dev/null && return
    aws ssm put-parameter --name "$VM_PARAMETER_PATH$1" --type "$2" --overwrite --value "file://"<(printf '%s' "$3") >/dev/null
    parameters_changed=1
}
set_vm_parameter acme-email String "$ACME_EMAIL"
set_vm_parameter domain String "$DOMAIN"
set_vm_parameter website-alias-domains String "$WEBSITE_ALIAS_DOMAINS"
set_vm_parameter mta-sts-policy String "$mta_sts_policy"
set_vm_parameter image-public-key String "$image_public_key"
set_vm_parameter mail-user String "$MAIL_USER"
set_vm_parameter mail-alias-domains String "$MAIL_ALIAS_DOMAINS"
set_vm_parameter tailnet-dns-name String "$TAILNET_DNS_NAME"
set_vm_parameter dkim-selector String "$dkim_selector"
set_vm_parameter dkim-public-key String "$dkim_public_key"
set_vm_parameter web-push-public-key String "$web_push_public_key"
[ "$pending_secrets" = '{}' ] || \
    set_vm_parameter pending-secrets SecureString "$pending_secrets"
# The hash follows pending-secrets, so a run that stops between the two writes sends the password
# again.
set_vm_parameter relay-password-sha256 String "$relay_password_sha256"
if [ -n "$vm_instance_id" ]; then
    # The VM reads its parameters at boot, so it boots again when a value changed. It also boots
    # again while secrets are pending, because remove-boot-secrets.sh removes pending-secrets once
    # any boot finished, and only a boot after this run's write has stored these pending secrets.
    if [ -n "$parameters_changed" ] || [ "$pending_secrets" != '{}' ]; then
        aws ec2 reboot-instances --instance-ids "$vm_instance_id"
    fi
else
    # The operator-tools image's PostgreSQL hashes the password, which it reads from stdin, and the
    # AWS CLI reads the hash from the pipe on /dev/fd/0. initdb refuses to run as root, so the hasher
    # runs as postgres.
    printf '%s' "$POSTGRESQL_EXPERIMENTS_PASSWORD" | runuser -u postgres -- /hash-postgresql-password/run.sh | tr -d '\n' | \
        aws ssm put-parameter --name "${VM_PARAMETER_PATH}postgresql-experiments-password-hash" --type SecureString --value file:///dev/fd/0 >/dev/null
    # The first boot logs in with this key, and every later boot reuses the node key in tailscaled's
    # state on /var. A tagged node's key never expires, so the auth key needs to last only until the
    # first boot, and a non-ephemeral node stays registered while the VM reboots.
    tailscale_auth_key=$(jq -n '{capabilities: {devices: {create: {reusable: false, ephemeral: false, preauthorized: true, tags: ["tag:vm"]}}}, expirySeconds: 3600, description: "bootc-vm first boot"}' | \
        call_tailscale_api -H 'Content-Type: application/json' --data @- "$tailscale_api_base/tailnet/-/keys" | jq -er .key)
    # Under Tailnet Lock, the VM signs its own node key with a credential that this machine's lock key
    # wraps into the auth key, so the coordination server never picks the node key this machine trusts.
    # The end of the run removes the auth key's credential.
    lock_enabled=$(tailscale lock status --json | jq .Enabled)
    if [ "$lock_enabled" = true ]; then
        tailscale_auth_key=$(tailscale lock sign file:<(printf '%s' "$tailscale_auth_key"))
    fi
    set_vm_parameter tailscale-auth-key SecureString "$tailscale_auth_key"
    # The firmware keys come from the VM AMI, and the role lets the VM read its parameters and
    # pull its image. A hop limit of 1 keeps the role's credentials from anything behind a NAT.
    vm_ami_id=$(fetch_vm_ami ImageId)
    vm_interface=$(fetch_stack_output VmInterface)
    aws ec2 run-instances --image-id "$vm_ami_id" --instance-type "$VM_INSTANCE_TYPE" --network-interfaces "NetworkInterfaceId=$vm_interface,DeviceIndex=0" --iam-instance-profile Name=bootc-vm \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VM_BOOT_VOLUME_SIZE,VolumeType=gp3}" --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1 --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$vm_name}]" >/dev/null
fi

"$PWD/remove-boot-secrets.sh"

# This machine signs the VM's node key under a rotation key whose private half no one keeps, so no one
# can move the signature. Removing the auth key's credential re-signs nothing, since re-signing would
# keep its key as the VM's rotation key. A terminal would make `lock remove` ask for confirmation.
lock_status=$(tailscale lock status --json)
vm_peer=$(printf '%s' "$lock_status" | jq -c --arg name "$REPOSITORY.$TAILNET_DNS_NAME." '[.VisiblePeers[]? | select(.DNSName == $name and .NodeKeySignature.Nested.SigKind? == "credential")][0] // empty')
if [ -n "$vm_peer" ]; then
    vm_node_key=$(printf '%s' "$vm_peer" | jq -er .NodeKey)
    credential_key=$(printf '%s' "$vm_peer" | jq -er .NodeKeySignature.Nested.KeyID)
    credential_node_count=$(printf '%s' "$lock_status" | jq --arg key "$credential_key" '[.VisiblePeers[] | select(.NodeKeySignature.Nested.KeyID? == $key)] | length')
    rotation_key=$(openssl genpkey -algorithm ed25519 | openssl pkey -pubout -outform DER | tail -c 32 | od -An -tx1 -v | tr -d ' \n')
    [ "$credential_node_count" != 1 ] || \
        tailscale lock sign "$vm_node_key" "tlpub:$rotation_key"
    tailscale lock remove --re-sign=false "$credential_key" >/dev/null
    if [ "$credential_node_count" != 1 ]; then
        echo "$credential_node_count nodes carried the VM auth key's credential, which is now removed. Check 'tailscale lock status' and sign the VM's node key." >&2
        exit 1
    fi
fi
