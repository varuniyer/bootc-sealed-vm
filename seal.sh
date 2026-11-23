#!/usr/bin/env bash
set -euo pipefail

# Runs in the sealing-tools image without a network, on the directory that build-and-publish.sh
# mounts at /sealed. The Secure Boot and PCR keys stay in KMS, so each step here stops where a
# signature is due, and build-and-publish.sh has KMS make it before the next step.
sealed=/sealed
boot=$sealed/boot
uki=$sealed/uki

# pesign signs through an NSS database, which here holds only the Secure Boot certificate.
create_pesign_database() {
    mkdir /tmp/nss
    certutil -N -d /tmp/nss --empty-password
    certutil -A -d /tmp/nss -n secureboot -t ,,P -i $sealed/secureboot.crt
}

# Writes the attributes that the signature on each EFI binary in the directory $1 covers.
export_attributes() {
    local binary
    create_pesign_database
    for binary in "$1"/*.efi; do
        pesign --certdir /tmp/nss -c secureboot -d sha256 -i "$binary" -E "$binary.sattrs"
    done
}

# Builds the flattened image's UKI into the directory $1. The image is mounted at /target, and
# split-kernel-and-rootfs left its kernel in /kernel.
build_uki() {
    local kver
    kver=$(ls /target/kernel)
    bootc container ukify --rootfs /target --kernel-dir "/target/kernel/$kver" -- --output "$1/$kver.efi" --pcr-banks sha256 "${@:2}"
}

case $1 in
    boot-attributes)
        mkdir $boot
        cp /usr/lib/systemd/boot/efi/systemd-boot*.efi $boot
        export_attributes $boot
        ;;
    # RHEL's crypto policy rejects SHA-1 signatures, so the PCR 11 policy covers the SHA-256 bank
    # alone. The signature covers PCR 11 only through leave-initrd. fstab's /var mount orders the
    # unlock before sysinit.target, after which systemd-pcrphase-sysinit extends PCR 11.
    uki-policy)
        openssl genrsa -out /tmp/policy.key 2048
        build_uki /tmp --pcr-private-key /tmp/policy.key --pcr-public-key $sealed/pcr.pub.pem --phases=enter-initrd:leave-initrd
        objcopy -O binary --only-section=.pcrsig /tmp/*.efi $sealed/pcr-policy.json
        ;;
    # The UKI's signature covers the embedded kernel, which systemd-stub starts without verifying it
    # again.
    uki-attributes)
        mkdir $uki
        build_uki $uki --pcrpkey $sealed/pcr.pub.pem --section ".pcrsig:@$sealed/pcr-signature.json"
        export_attributes $uki
        ;;
    # Attaches the signature KMS made over each binary's attributes in the directory $sealed/$2, and
    # names each signed binary with the suffix $3. bootctl installs a .signed binary in place of the
    # unsigned one beside it.
    attach)
        create_pesign_database
        mkdir "$sealed/$2/signed"
        for binary in "$sealed/$2"/*.efi; do
            pesign --certdir /tmp/nss -c secureboot -d sha256 -i "$binary" -I "$binary.sattrs" -R "$binary.sig" -o "$sealed/$2/signed/${binary##*/}${3-}"
        done
        ;;
esac
