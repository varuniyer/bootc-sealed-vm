#!/usr/bin/env bash
set -euo pipefail

fetch=/opt/scripts/fetch-parameter.sh
# An empty key lists the VM's Parameter Store keys.
keys=$($fetch '')
# remove-boot-secrets.sh removes pending-secrets from Parameter Store once a boot finished, so each
# boot stores the pending secrets and then reads only the secret store. A key that pending-secrets
# lacks keeps its stored value, and the sync makes the stored values outlast a reboot.
if grep -qx pending-secrets <<< "$keys"; then
    pending_secrets=$($fetch pending-secrets)
    jq -r 'keys[]' <<< "$pending_secrets" | while read -r key; do
        jq -j --arg key "$key" '.[$key]' <<< "$pending_secrets" > "$STATE_DIRECTORY/$key.new"
        mv "$STATE_DIRECTORY/$key.new" "$STATE_DIRECTORY/$key"
    done
    sync -f "$STATE_DIRECTORY"
fi

# caddy.service loads this file with EnvironmentFile=, and Caddy fills the Caddyfile's {$VAR}
# placeholders from that environment. Caddy separates site addresses with spaces.
domain=$($fetch domain)
acme_email=$($fetch acme-email)
website_alias_domains=$($fetch website-alias-domains)
printf 'DOMAIN=%s\nACME_EMAIL=%s\nWEBSITE_ALIAS_DOMAINS=%s\n' "$domain" "$acme_email" "${website_alias_domains//,/ }" > /run/caddy/env

mkdir -p /run/caddy/mta-sts/.well-known
$fetch mta-sts-policy > /run/caddy/mta-sts/.well-known/mta-sts.txt

# stalwart-apply.sh applies the plan rendered here, and Stalwart reads its DKIM and Web Push keys and
# its relay password from the files the plan names.
mail_alias_domains=$($fetch mail-alias-domains)
mail_user=$($fetch mail-user)
dkim_selector=$($fetch dkim-selector)
jq -nc --arg domain "$domain" --arg mail_alias_domains "$mail_alias_domains" --arg acme_email "$acme_email" --arg dkim_selector "$dkim_selector" \
    --arg mail_user "$mail_user" --rawfile mail_password_hash "$STATE_DIRECTORY/mail-password-hash" -f /usr/share/stalwart/plan.jq > /run/stalwart/plan.ndjson
cp "$STATE_DIRECTORY/dkim-key" "$STATE_DIRECTORY/web-push-key" "$STATE_DIRECTORY/relay-password" /run/stalwart/
# Tailnet clients reach Stalwart through tailscale serve under the node's MagicDNS name.
tailnet=$($fetch tailnet)
printf 'STALWART_PUBLIC_URL=https://bootc-sealed-vm.%s\n' "$tailnet" > /run/stalwart/env

# containers/policy.json accepts image updates only when signed by this key.
$fetch image-public-key > /etc/pki/containers/image.pub

if [ ! -d "$PGDATA" ]; then
    $fetch postgresql-experiments-hash > "$RUNTIME_DIRECTORY/hash"
fi
