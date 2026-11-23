#!/usr/bin/env bash
set -euo pipefail

# / is a composefs mount backed by no block device, so systemd-repart cannot find the disk that
# holds the root partition by itself. /sysroot is that partition's own mount.
root_partition=$(findmnt -fno SOURCE /sysroot)
disk=$(lsblk -no PKNAME "$root_partition")
# PCR 7 records the Secure Boot state and keys, so /var stays locked when Secure Boot is off. The
# PCR 11 policy admits any UKI whose PCR 11 values the PCR key signed, so image updates keep
# unlocking it. systemd-stub passes the PCR key's public half from the UKI to the initramfs, which copies it to /run.
exec systemd-repart --dry-run=no --tpm2-device=auto --tpm2-pcrs=7 --tpm2-public-key=/run/systemd/tpm2-pcr-public-key.pem --tpm2-public-key-pcrs=11 "/dev/$disk"
