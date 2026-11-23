#!/usr/bin/env bash
set -euo pipefail

# The marker needs its own StateDirectory because this unit drops CAP_DAC_OVERRIDE
# and /var/lib/tailscale is 0700 to tailscaled's DynamicUser.
marker=$STATE_DIRECTORY/logged-in
if [ ! -f "$marker" ]; then
    # The auth key flows through a file (private /tmp) so it stays out of argv.
    key_file=$(mktemp)
    /opt/scripts/fetch-parameter.sh tailscale-auth-key > "$key_file"

    tailscale up --auth-key="file:$key_file" --hostname=bootc-sealed-vm --advertise-tags=tag:vm \
        --accept-dns=false --accept-routes=false --ssh=false
    rm "$key_file"
    touch "$marker"
fi

# serve --https needs the netmap's cert domains, which arrive with the node's IPs.
until tailscale ip -4 >/dev/null 2>&1; do sleep 1; done

# Serve config persists in tailscaled state, so every boot resets it to match this file.
tailscale serve reset
tailscale serve --bg --tcp 5432 tcp://127.0.0.1:5432
# Stalwart's HTTP listener (JMAP, CalDAV, CardDAV, WebDAV), IMAP, and submission listen in plaintext
# on loopback.
tailscale serve --bg --https 443 http://127.0.0.1:9000
# Stalwart's loopback listeners require a PROXY header, which names the client's tailnet address
# (see plan.jq).
tailscale serve --bg --tls-terminated-tcp 993 --proxy-protocol 2 tcp://127.0.0.1:143
tailscale serve --bg --tls-terminated-tcp 465 --proxy-protocol 2 tcp://127.0.0.1:587
# publish-tlsa.sh reads Stalwart's own certificate here for the DANE TLSA record, because many
# networks block outbound port 25.
tailscale serve --bg --tcp 25 --proxy-protocol 2 tcp://127.0.0.1:25
