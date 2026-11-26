#!/usr/bin/env bash
set -euo pipefail

# DANE senders deliver only to the key the TLSA record pins. This pins the key of the certificate
# Stalwart serves once Let's Encrypt's chain validates it for mail.<DOMAIN>. A failed check changes
# nothing, because a record that pins the current key must survive a passing network fault.

# operator-tools.sh runs this script in the operator-tools image, which supplies every tool it uses.
[ -n "${OPERATOR_TOOLS:-}" ] || \
    exec "$PWD/operator-tools.sh" "./${0##*/}" "$@"
source "$PWD/build.env"
source "$PWD/region.sh"
source "$PWD/desec.sh"

# tailscale/policy.json lets only tag:operator reach the VM's tailnet port 25.
operator_tag_missing=$(fetch_this_machine | jq .operator_tag_missing)
if [ "$operator_tag_missing" = true ]; then
    echo 'This machine lacks tag:operator, so it cannot reach the VM on tailnet port 25. Tag it first (see README).' >&2
    exit 1
fi

# provision.sh sets both values among the VM's parameters.
domain=$(aws ssm get-parameter --name "${VM_PARAMETERS}domain" --query Parameter.Value --output text)
tailnet=$(aws ssm get-parameter --name "${VM_PARAMETERS}tailnet" --query Parameter.Value --output text)
create_desec_token publish-tlsa

if ! spki_hash=$(timeout 30 openssl s_client -starttls smtp -connect "$REPOSITORY.$tailnet:25" -servername "mail.$domain" -verify_hostname "mail.$domain" -verify_return_error </dev/null 2>/dev/null | \
        openssl x509 -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1); then
    echo "No certificate that validates for mail.$domain at $REPOSITORY.$tailnet:25, so the TLSA record is unchanged." >&2
    exit 1
fi

record="3 1 1 $spki_hash"
name=_25._tcp.mail.$domain
zone=$(fetch_zone "$name")
subname=$(strip_zone "$name" "$zone")
rrset=$(format_rrset "$subname" TLSA "[\"$record\"]")
write_rrsets "$zone" "[$rrset]"
echo "Set $name to $record." >&2
