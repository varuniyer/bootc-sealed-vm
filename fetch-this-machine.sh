# Prints this machine's tailnet device ID and tags, and whether it lacks tag:operator.
fetch_this_machine() { tailscale status --json | jq -c '.Self | {id: .ID, tags: (.Tags // [])} | .operator_tag_missing = (.tags | index("tag:operator") == null)'; }
