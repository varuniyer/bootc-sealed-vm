#!/usr/bin/env bash
set -euo pipefail

# Runs a command, or a shell, in the provisioner image, which every run builds from Red Hat's signed
# base image and signed packages. This machine supplies only bash, Podman, its tailscaled, and ~/.aws.

podman login --get-login registry.redhat.io >/dev/null 2>&1 || \
    {
        echo "Podman's login to registry.redhat.io takes the registry service account's username and token, not your Red Hat login." >&2
        podman login registry.redhat.io
    }
run_dir=$(mktemp -d -p "${XDG_RUNTIME_DIR:?}")
trap 'rm -r "$run_dir"' EXIT
# Sigstore attachments carry Red Hat's signature on the base image, which build-policy.json requires.
# Podman reads registries.d only from its config directory, so the pull takes one made for this run.
mkdir -p "$run_dir/entitlement" "$run_dir/config/containers/registries.d" "$HOME/.aws"
cp containers/bootc-sealed-vm.yaml "$run_dir/config/containers/registries.d/"
XDG_CONFIG_HOME=$run_dir/config podman pull -q --signature-policy containers/build-policy.json registry.redhat.io/rhel10/rhel-bootc:latest >/dev/null

# The base image's /home is a symbolic link, so the checkout mounts at /repository.
build=(podman build -q --layers=false --pull=never -f Containerfile)
run=(podman run --rm -it --pull=never --log-driver=none --network=host --security-opt label=disable -v "$PWD:/repository" -w /repository -v "$HOME/.aws:/root/.aws")
# entitlement.sh leaves the builds' entitlement certificate and key on the run's tmpfs directory. The
# tmpfs mounts hold the registration it makes while Secrets Manager holds no valid certificate.
"${build[@]}" --target aws-cli -t localhost/aws-cli . >/dev/null
"${run[@]}" -e SMDEV_CONTAINER_OFF=1 --tmpfs /etc/pki/consumer --tmpfs /etc/pki/entitlement -v "$run_dir/entitlement:/entitlement" localhost/aws-cli ./entitlement.sh
"${build[@]}" --target provisioner -t localhost/provisioner --secret "id=entitlement_certificate,src=$run_dir/entitlement/certificate" --secret "id=entitlement_key,src=$run_dir/entitlement/key" . >/dev/null

# The container shares this machine's network, so it reaches the tailnet, and the tailscale CLI in it
# drives this machine's tailscaled through the socket. /tmp holds the PostgreSQL hasher's server.
# PROVISIONER marks the inside for the scripts.
"${run[@]}" --tmpfs /tmp -e PROVISIONER=1 -v /run/tailscale/tailscaled.sock:/run/tailscale/tailscaled.sock localhost/provisioner "${@:-bash}"
