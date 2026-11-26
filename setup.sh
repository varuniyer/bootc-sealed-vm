#!/usr/bin/env bash
set -euo pipefail

# Nothing logs into the VM.
dnf remove -y openssh-server openssh-clients
rm -rf /etc/ssh
# nfs-utils, gssproxy, and rpcbind serve NFS. subscription-manager, insights-client, and rhc
# register the system with Red Hat and report to it. The image uses none of them.
dnf remove -y nfs-utils gssproxy rpcbind subscription-manager insights-client rhc
# bootc installs systemd-boot, which boots the sealed UKI, only while bootupd is absent. bootupd's
# payload in /usr/lib/bootupd belongs to no RPM.
dnf remove -y bootupd
rm -r /usr/lib/bootupd
# Red Hat publishes errata between rebuilds of the base image, and the daily build takes them. The
# base image's dnf.conf empties installonlypkgs, so a kernel errata replaces the image's one kernel.
dnf upgrade -y
# An upgraded kernel's scriptlet copies symvers into /boot, which a bootc image leaves to the UKI.
rm -f /boot/symvers-*
dnf install -y tailscale postgresql17-server systemd-boot-unsigned
dnf clean all
# CacheDirectory= creates /var/cache/tailscale at start. Under DynamicUser=, systemd migrates the RPM's
# root-owned copy into /var/cache/private, a rename that fails across overlay layers.
rmdir /var/cache/tailscale
# PGDG's RPM installs a per-version data tree and a login profile, and pgdata.conf's data directory uses neither.
rm -r /var/lib/pgsql/17 /var/lib/pgsql/.bash_profile
# PGDG's RPM gives postgres a login shell.
usermod -s /usr/sbin/nologin postgres
# systemd-getty-generator adds a login prompt on the kernel's serial console.
# Masking the template drops it, and the console output stays readable.
systemctl mask serial-getty@.service
# Growing the root partition would take the free space that systemd-repart gives /var.
systemctl mask bootc-generic-growpart.service
# irqbalance.service sets PrivateUsers, and kernel-restrictions.conf allows no user namespace, so it
# fails at every boot. The VM has one vCPU, which leaves no interrupts to balance.
systemctl mask irqbalance.service
# systemd-sysext and systemd-confext merge extensions from /var/lib/extensions and /var/lib/confexts
# over /usr and /etc before sysinit.target. The image contains none, and the composefs digest covers
# no file on /var.
systemctl mask systemd-sysext.service systemd-confext.service

semodule -n -i /usr/share/selinux/packages/bootc-sealed-vm/*.pp
# COPY'd binaries and the paths the modules label need SELinux labels.
restorecon -R /usr/bin /usr/sbin /usr/pgsql-17 /etc/caddy /etc/stalwart

groupadd -r caddy
useradd -r -g caddy -d /var/lib/caddy -s /usr/sbin/nologin caddy
groupadd -r stalwart
useradd -r -g stalwart -d /var/lib/stalwart -s /usr/sbin/nologin stalwart

mkdir /etc/pki/containers

# bootc's dracut module embeds setup-root-conf.toml in the initramfs, which applies it before the root mounts.
KVER=$(basename /usr/lib/modules/*)
dracut --no-hostonly --force --kver "$KVER" /usr/lib/modules/"$KVER"/initramfs.img
# The UKI embeds the kernel and initramfs, so they move from /usr/lib/modules to /kernel, where
# seal.sh's build_uki reads them.
bootc container split-kernel-and-rootfs --rootfs / --output /kernel

# The base image contains group-writable files that its own RPMs declare 0644,
# and a umask-002 checkout makes COPY'd files group-writable.
find /usr /etc /opt \( -type f -o -type d \) -perm /022 -exec chmod go-w {} +

chown root:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile

# boot-configuration.service runs as Group=pghash, so the hash file it writes
# belongs to pghash, and postgres reads it as a member.
groupadd -r pghash
usermod -aG pghash postgres

# Every unit this repository provides links the shared restrictions.
for unit in boot-configuration modules-disabled boot-tailscale boot-postgresql tailscaled caddy postgresql stalwart-apply stalwart; do
    mkdir -p /usr/lib/systemd/system/$unit.service.d
    ln -s ../../service-restrictions.conf /usr/lib/systemd/system/$unit.service.d/service-restrictions.conf
done
for unit in boot-postgresql postgresql; do
    ln -s ../../run-as-postgres.conf /usr/lib/systemd/system/$unit.service.d/run-as-postgres.conf
done
for unit in stalwart-apply stalwart; do
    ln -s ../../run-as-stalwart.conf /usr/lib/systemd/system/$unit.service.d/run-as-stalwart.conf
done
for unit in boot-configuration boot-postgresql postgresql; do
    ln -s ../../pgdata.conf /usr/lib/systemd/system/$unit.service.d/pgdata.conf
done

systemctl enable nftables tailscaled boot-tailscale caddy.socket caddy postgresql stalwart modules-disabled bootc-fetch-apply-updates.timer

bootc container lint
