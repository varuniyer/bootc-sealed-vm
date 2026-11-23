#!/usr/bin/env bash
set -euo pipefail

# Runs as root on a build instance (see infrastructure.yaml). The instance's role reads the build's
# secrets, signs with the KMS keys, pushes the image, and replaces the seed image.
dnf install -y -q podman skopeo jq gh openssl python3-virt-firmware
source "$PWD/build.env"
source "$PWD/region.sh"
source "$PWD/fetch-secret.sh"

# The token reaches curl through its config on stdin, so it stays out of argv.
instance=$(curl -sSf -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token | \
    jq -Rr '"header = \("X-aws-ec2-metadata-token: " + . | @json)"' | curl -sSf -K - http://169.254.169.254/latest/meta-data/instance-id)
# A newer build ends every older one, whose image would otherwise replace this build's. EC2 reports
# launch times to the second, so the instance ID orders builds launched in the same second.
older_builds=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$BUILD_INSTANCE_NAME" Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[]' | \
    jq -r --arg instance "$instance" '(.[] | select(.InstanceId == $instance) | [.LaunchTime, .InstanceId]) as $this_build | .[] | select([.LaunchTime, .InstanceId] < $this_build).InstanceId')
[ -z "$older_builds" ] || \
    aws ec2 terminate-instances --instance-ids $older_builds >/dev/null

bash tailscale/apply-policy.sh

# Downloads the asset $3 of the release $2 of the GitHub repository $1, and accepts it only when its
# attestation shows that the GitHub repository's workflow $4 built it from the ref $5. GitHub serves a
# public repository's attestations without a login.
fetch_attested() {
    local hash
    curl -sSfL -o "$3" "https://github.com/$1/releases/download/$2/$3"
    hash=$(sha256sum "$3" | cut -d' ' -f1)
    curl -sSf "https://api.github.com/repos/$1/attestations/sha256:$hash" | jq -c '.attestations[].bundle' > "$3.jsonl"
    gh attestation verify "$3" --bundle "$3.jsonl" --repo "$1" --signer-workflow "$1/.github/workflows/$4" --source-ref "$5"
}
fetch_latest_release() { curl -sSf "https://api.github.com/repos/$1/releases/latest" | jq -er .tag_name; }
# The website repository's publish workflow on main builds and attests site.tar.gz, and the site stage
# unpacks it only after this check.
fetch_attested "$WEBSITE_REPOSITORY" site-tarball site.tar.gz publish.yml refs/heads/main
# Stalwart's release workflows build and attest the server and CLI tarballs from each release tag,
# and the stalwart stage unpacks them only after these checks.
stalwart_tag=$(fetch_latest_release stalwartlabs/stalwart)
fetch_attested stalwartlabs/stalwart "$stalwart_tag" stalwart-aarch64-unknown-linux-gnu.tar.gz ci.yml "refs/tags/$stalwart_tag"
cli_tag=$(fetch_latest_release stalwartlabs/cli)
fetch_attested stalwartlabs/cli "$cli_tag" stalwart-cli-aarch64-unknown-linux-gnu.tar.xz release.yml "refs/tags/$cli_tag"
# The spam filter's rule set carries no signature or attestation. The image accepts it because a bad
# rule set can at worst misfile or reject mail.
curl -sSfL -O https://github.com/stalwartlabs/spam-filter/releases/latest/download/spam-filter-rules.json.gz

build_secret=$(fetch_secret "$BUILD_SECRET")
RHSM_ENTITLEMENT_CERTIFICATE=$(fetch_secret "$ENTITLEMENT_CERTIFICATE_SECRET")
RHSM_ENTITLEMENT_KEY=$(jq -er .entitlement_key <<< "$build_secret")
export RHSM_ENTITLEMENT_CERTIFICATE RHSM_ENTITLEMENT_KEY
redhat_registry_username=$(jq -er .redhat_registry_username <<< "$build_secret")
jq -ej .redhat_registry_token <<< "$build_secret" | podman login --password-stdin -u "$redhat_registry_username" registry.redhat.io
IMAGE=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$REPOSITORY:latest
aws ecr get-login-password | podman login --password-stdin -u AWS "${IMAGE%%/*}"
# Sigstore attachments carry Red Hat's signature on the base image and this build's signature for the VM.
mkdir -p /etc/containers/registries.d && cp containers/bootc-sealed-vm.yaml /etc/containers/registries.d/

# Prints the base64 signature that the KMS key $1 makes over the file $3 with the algorithm $2.
kms_sign() { aws kms sign --key-id "$1" --signing-algorithm "$2" --message-type RAW --message "fileb://$3" --query Signature --output text; }
# pesign wrote the attributes that each EFI binary's signature covers in the directory sealed/$1,
# and the Secure Boot key signs them.
sign_attributes() {
    local attributes
    for attributes in "sealed/$1"/*.sattrs; do
        kms_sign "$SECUREBOOT_KEY" RSASSA_PKCS1_V1_5_SHA_256 "$attributes" | base64 -d > "${attributes%.sattrs}.sig"
    done
}

# seal.sh runs without a network and exchanges files with this script through sealed/.
mkdir sealed
aws ssm get-parameter --name "${BUILD_PARAMETERS}secureboot-certificate" --query Parameter.Value --output text > sealed/secureboot.crt
aws kms get-public-key --key-id "$PCR_KEY" --query PublicKey --output text | base64 -d | openssl pkey -pubin -inform DER -out sealed/pcr.pub.pem
# --pull=always checks the base image against build-policy.json for each stage that pulls it.
build=(podman build --layers=false --signature-policy containers/build-policy.json --secret id=entitlement_certificate,env=RHSM_ENTITLEMENT_CERTIFICATE --secret id=entitlement_key,env=RHSM_ENTITLEMENT_KEY -f Containerfile)
seal=(podman run --rm --network=none -v "$PWD/sealed:/sealed:Z")
flattened=(--mount type=image,source=localhost/flattened,destination=/target)

"${build[@]}" --pull=always --target sealing-tools -t localhost/sealing-tools .
"${seal[@]}" localhost/sealing-tools bash /seal.sh boot-attributes
sign_attributes boot
"${seal[@]}" localhost/sealing-tools bash /seal.sh attach boot .signed

"${build[@]}" --pull=always --target flattened -t localhost/flattened .
"${seal[@]}" "${flattened[@]}" localhost/sealing-tools bash /seal.sh uki-policy
jq -ej '.sha256 | if length == 1 then .[0].pol | ascii_upcase else error("expected one PCR policy") end' sealed/pcr-policy.json | basenc -d --base16 > sealed/pcr-policy
pcr_signature=$(kms_sign "$PCR_KEY" RSASSA_PKCS1_V1_5_SHA_256 sealed/pcr-policy)
jq -c --arg signature "$pcr_signature" '.sha256[0].sig = $signature' sealed/pcr-policy.json > sealed/pcr-signature.json
"${seal[@]}" "${flattened[@]}" localhost/sealing-tools bash /seal.sh uki-attributes
sign_attributes uki
"${seal[@]}" localhost/sealing-tools bash /seal.sh attach uki

"${build[@]}" --pull=never --target sealed -t "$IMAGE" .
podman push --digestfile sealed/digest "$IMAGE"

# The VM accepts an update only with this signature, which containers/policy.json checks against the
# image key's public half. The registry holds it as a sigstore attachment: an image, tagged with the
# signed image's digest, whose one layer is the signed payload and whose annotation is the signature.
digest=$(<sealed/digest)
attachment=sealed/attachment
mkdir -p $attachment/blobs/sha256
# Stores the file $1 as a blob of the attachment and prints its descriptor.
store_blob() {
    local hash size
    hash=$(sha256sum "$1" | cut -d' ' -f1)
    size=$(stat -c %s "$1")
    cp "$1" "$attachment/blobs/sha256/$hash"
    jq -nc --arg digest "sha256:$hash" --argjson size "$size" '{$digest, $size}'
}
jq -ncj --arg reference "$IMAGE" --arg digest "$digest" '{critical: {identity: {"docker-reference": $reference}, image: {"docker-manifest-digest": $digest}, type: "cosign container image signature"}, optional: null}' > sealed/payload
payload=$(store_blob sealed/payload)
jq -ncj --argjson payload "$payload" '{architecture: "", os: "", config: {}, rootfs: {type: "layers", diff_ids: [$payload.digest]}}' > sealed/config
config=$(store_blob sealed/config)
image_signature=$(kms_sign "$IMAGE_KEY" ECDSA_SHA_256 sealed/payload)
jq -ncj --argjson payload "$payload" --argjson config "$config" --arg signature "$image_signature" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", config: ({mediaType: "application/vnd.oci.image.config.v1+json"} + $config),
    layers: [{mediaType: "application/vnd.dev.cosign.simplesigning.v1+json"} + $payload + {annotations: {"dev.cosignproject.cosign/signature": $signature}}]}' > sealed/manifest
manifest=$(store_blob sealed/manifest)
printf '{"imageLayoutVersion":"1.0.0"}' > $attachment/oci-layout
jq -nc --argjson manifest "$manifest" '{schemaVersion: 2, manifests: [{mediaType: "application/vnd.oci.image.manifest.v1+json"} + $manifest]}' > $attachment/index.json
skopeo copy "oci:$attachment" "docker://${IMAGE%:*}:${digest/:/-}.sig"

# The image installs itself onto the instance's second volume, which becomes the seed image's
# snapshot. --generic-image leaves the instance's own firmware variables alone.
volume=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$instance" Name=attachment.device,Values=/dev/sdf --query 'Volumes[0].VolumeId' --output text)
GRAPH_ROOT=$(podman info --format '{{.Store.GraphRoot}}')
podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t -v /dev:/dev -v "$GRAPH_ROOT:/var/lib/containers/storage" \
  "$IMAGE" bootc install to-disk --generic-image --composefs-backend --bootloader systemd --filesystem ext4 --root-size 30G "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volume/-/}"
sync
snapshot=$(aws ec2 create-snapshot \
    --volume-id "$volume" \
    --description "$SEED_IMAGE" \
    --query SnapshotId --output text)
# The waiter gives up after ten minutes, and a first snapshot of the volume can take longer.
aws ec2 wait snapshot-completed --snapshot-ids "$snapshot" || aws ec2 wait snapshot-completed --snapshot-ids "$snapshot"

# The VM's firmware trusts only this certificate, as its platform key, key exchange key, and signature
# database. The GUID names the entries' owner, and a fixed one keeps PCR 7 the same for every VM.
owner=6e0c3a2a-58c5-4b0b-9d2f-7b7a3c1f4e11
virt-fw-vars --set-pk $owner sealed/secureboot.crt --add-kek $owner sealed/secureboot.crt --add-db $owner sealed/secureboot.crt --secure-boot --output-aws sealed/uefi-data
old_seed_image=$(aws ec2 describe-images --owners self --filters "Name=name,Values=$SEED_IMAGE" --query 'Images[].[ImageId,BlockDeviceMappings[0].Ebs.SnapshotId]' --output text)
if [ -n "$old_seed_image" ]; then
    read -r old_seed_image_id old_snapshot <<< "$old_seed_image"
    aws ec2 deregister-image --image-id "$old_seed_image_id"
    aws ec2 delete-snapshot --snapshot-id "$old_snapshot"
fi
aws ec2 register-image --name "$SEED_IMAGE" --architecture arm64 --boot-mode uefi --tpm-support v2.0 --ena-support --virtualization-type hvm --root-device-name /dev/sda1 \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=$snapshot,VolumeType=gp3}" --uefi-data "$(<sealed/uefi-data)" >/dev/null
