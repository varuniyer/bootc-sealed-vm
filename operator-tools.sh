#!/usr/bin/env bash
set -euo pipefail

# Runs a command, or a shell, in the operator-tools image, which every run builds from Red Hat's
# signed base image and signed packages. This machine supplies only bash, Podman, its tailscaled,
# ~/.aws, and for provision.sh the website's checkout, whose path WEBSITE_CHECKOUT holds.

podman login --get-login registry.redhat.io >/dev/null 2>&1 || \
    {
        echo "Podman's login to registry.redhat.io takes the registry service account's username and token, not your Red Hat login." >&2
        podman login registry.redhat.io
    }
run_directory=$(mktemp -d -p "${XDG_RUNTIME_DIR:?}")
trap 'rm -r "$run_directory"' EXIT
# Sigstore attachments carry Red Hat's signature on the base image, which base-image-policy.json
# requires. Podman reads registries.d only from its configuration directory, so the pull takes one
# made for this run.
mkdir -p "$run_directory/entitlement" "$run_directory/config/containers/registries.d" "$HOME/.aws"
cp containers/sigstore-attachments.yaml "$run_directory/config/containers/registries.d/"
XDG_CONFIG_HOME=$run_directory/config podman pull -q --signature-policy containers/base-image-policy.json registry.redhat.io/rhel10/rhel-bootc:latest >/dev/null

# The base image's /home is a symbolic link, so the checkout mounts at /repository.
podman_build=(podman build -q --layers=false --pull=never -f Containerfile)
podman_run=(podman run --rm -it --pull=never --log-driver=none --network=host --security-opt label=disable -v "$PWD:/repository" -w /repository -v "$HOME/.aws:/root/.aws")
# entitlement.sh leaves the builds' entitlement certificate and key on the run's tmpfs directory. The
# tmpfs mounts hold the registration it makes while Secrets Manager holds no valid certificate.
"${podman_build[@]}" --target aws-cli -t localhost/aws-cli . >/dev/null
"${podman_run[@]}" -e SMDEV_CONTAINER_OFF=1 --tmpfs /etc/pki/consumer --tmpfs /etc/pki/entitlement -v "$run_directory/entitlement:/entitlement" localhost/aws-cli ./entitlement.sh
"${podman_build[@]}" --target operator-tools -t localhost/operator-tools --secret "id=entitlement_certificate,src=$run_directory/entitlement/certificate" --secret "id=entitlement_key,src=$run_directory/entitlement/key" . >/dev/null

# The container shares this machine's network, so it reaches the tailnet, and the tailscale CLI in it
# controls this machine's tailscaled through the socket. /tmp holds the PostgreSQL hasher's server.
# OPERATOR_TOOLS tells each script that it runs inside the container.
website_mount=()
[ -z "${WEBSITE_CHECKOUT:-}" ] || website_mount=(-v "$WEBSITE_CHECKOUT:/website:ro")
"${podman_run[@]}" --tmpfs /tmp -e OPERATOR_TOOLS=1 -v /run/tailscale/tailscaled.sock:/run/tailscale/tailscaled.sock "${website_mount[@]}" localhost/operator-tools "${@:-bash}"
