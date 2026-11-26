#!/usr/bin/env bash
set -euo pipefail

# Allocates the VM's Elastic IP address and gives it the reverse DNS name $1, before provision.sh
# runs, which stops while the address is missing. AWS sets a reverse record only once the name's A
# record points at the address, so deSEC gets that record first.

# operator-tools.sh runs this script in the operator-tools image, which supplies every tool it uses.
[ -n "${OPERATOR_TOOLS:-}" ] || \
    exec "$PWD/operator-tools.sh" "./${0##*/}" "$@"
name=$1
source "$PWD/region.sh"
source "$PWD/read-secret.sh"
source "$PWD/desec.sh"

address_name=bootc-ip
address_allocation=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$address_name" --query 'Addresses[].AllocationId' --output text)
[ -n "$address_allocation" ] || \
    address_allocation=$(aws ec2 allocate-address --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$address_name}]" --query AllocationId --output text)
ip=$(aws ec2 describe-addresses --allocation-ids "$address_allocation" --query 'Addresses[0].PublicIp' --output text)

create_desec_token reserve-address
zone=$(fetch_zone "$name")
subname=$(strip_zone "$name" "$zone")
rrset=$(format_rrset "$subname" A "[\"$ip\"]")
write_rrsets "$zone" "[$rrset]"

# A resolver that asks before the zone's nameservers publish the A record caches the earlier answer
# for up to an hour, and AWS's resolver asks as soon as the request arrives.
nameservers=$(dig +short NS "$zone")
for nameserver in $nameservers; do
    while :; do
        nameserver_ip=$(dig +short A "$name" "@$nameserver")
        [ "$nameserver_ip" != "$ip" ] || break
        sleep 5
    done
done

# AWS applies a reverse record after the call returns, and refuses it while its resolver still
# lacks the A record, so the request repeats until the address carries the name.
fetch_reverse_record() { aws ec2 describe-addresses-attribute --allocation-ids "$address_allocation" --attribute domain-name --query "Addresses[0].$1" --output text; }
while :; do
    ptr_record=$(fetch_reverse_record PtrRecord)
    [ "$ptr_record" != "$name." ] || break
    aws ec2 modify-address-attribute --allocation-id "$address_allocation" --domain-name "$name" >/dev/null
    while :; do
        ptr_record_update_status=$(fetch_reverse_record PtrRecordUpdate.Status)
        [ "$ptr_record_update_status" = PENDING ] || break
        sleep 10
    done
    ptr_record=$(fetch_reverse_record PtrRecord)
    if [ "$ptr_record" != "$name." ]; then
        fetch_reverse_record PtrRecordUpdate.Reason >&2
        sleep 30
    fi
done
echo "$ip carries the reverse DNS name $name." >&2
