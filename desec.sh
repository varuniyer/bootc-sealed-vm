# A run asks for one deSEC token, a token-management token, and writes DNS through a token it creates
# for itself, whose policies deny every RRset except the ones the run writes.
# Every token reaches curl through a /dev/fd header file, so none appears in argv.
desec_api=https://desec.io/api/v1
call_desec() { curl -sSf -H @<(printf 'Authorization: Token %s' "$DESEC_TOKEN") "$@"; }
call_desec_token_management() { curl -sSf -H @<(printf 'Authorization: Token %s' "$DESEC_TOKEN_MANAGEMENT_TOKEN") "$@"; }
# deSEC serves each domain's zone, and owns_qname finds the zone that holds a name.
fetch_zone() { call_desec "$desec_api/domains/?owns_qname=$1" | jq -er '.[0].name'; }
# strip_zone prints the subname by which deSEC names an RRset in its zone, the part of the name $1
# below its zone $2.
strip_zone() { local subname=${1%"$2"}; printf '%s' "${subname%.}"; }
# format_rrset prints one RRset for write_rrsets: a subname, a type, and the records as a JSON array.
format_rrset() { jq -nc --arg subname "$1" --arg type "$2" --argjson records "$3" '{$subname, $type, ttl: 3600, $records}'; }

# Secrets stay unexported shell variables and reach other processes only through
# stdin or /dev/fd paths, never argv, the environment, or local disk.
read_secret() { read -rsp "$1: " "$2"; echo >&2; }

# Prints this machine's tailnet device ID and tags, and whether it lacks tag:operator.
fetch_this_machine() { tailscale status --json | jq -c '.Self | {id: .ID, tags: (.Tags // [])} | .operator_tag_missing = (.tags | index("tag:operator") == null)'; }

# $1 names the run's token, which holds none of deSEC's account permissions. The token gets its
# default-deny policy before any write, since deSEC lets a token without policies write every RRset.
# The sourcing script sets no EXIT trap, so this one, which deletes the token, holds.
create_desec_token() {
    local old_ids old_id token
    read_secret 'deSEC token-management token' DESEC_TOKEN_MANAGEMENT_TOKEN
    old_ids=$(call_desec_token_management "$desec_api/auth/tokens/" | jq -r --arg name "$1" '.[] | select(.name == $name) | .id')
    for old_id in $old_ids; do
        call_desec_token_management -X DELETE "$desec_api/auth/tokens/$old_id/" >/dev/null
    done
    token=$(jq -nc --arg name "$1" '{name: $name, perm_create_domain: false, perm_delete_domain: false, perm_manage_tokens: false}' | \
        call_desec_token_management -X POST -H 'Content-Type: application/json' --data @- "$desec_api/auth/tokens/")
    desec_token_id=$(printf '%s' "$token" | jq -er .id)
    trap 'call_desec_token_management -X DELETE "$desec_api/auth/tokens/$desec_token_id/" >/dev/null' EXIT
    DESEC_TOKEN=$(printf '%s' "$token" | jq -er .token)
    jq -nc '{domain: null, subname: null, type: null}' | \
        call_desec_token_management -X POST -H 'Content-Type: application/json' --data @- "$desec_api/auth/tokens/$desec_token_id/policies/rrsets/" >/dev/null
}

# Gives the run's token a write policy for each RRset in the JSON array $2, then PATCHes them into
# zone $1. One PATCH replaces each named RRset's whole record list, atomically.
write_rrsets() {
    local policies policy
    policies=$(printf '%s' "$2" | jq -c --arg zone "$1" '.[] | {domain: $zone, subname, type, perm_write: true}')
    for policy in $policies; do
        printf '%s' "$policy" | call_desec_token_management -X POST -H 'Content-Type: application/json' --data @- "$desec_api/auth/tokens/$desec_token_id/policies/rrsets/" >/dev/null
    done
    printf '%s' "$2" | call_desec -X PATCH -H 'Content-Type: application/json' --data @- "$desec_api/domains/$1/rrsets/" >/dev/null
}
