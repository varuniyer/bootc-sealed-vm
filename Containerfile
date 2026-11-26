FROM registry.redhat.io/rhel10/rhel-bootc:latest AS base


# build-and-publish.sh verifies the Stalwart server and CLI attestations before the build.
FROM scratch AS stalwart
ADD stalwart-aarch64-unknown-linux-gnu.tar.gz stalwart-cli-aarch64-unknown-linux-gnu.tar.xz /stalwart/
COPY spam-filter-rules.json.gz /stalwart/


# build.sh builds Caddy from its latest release tag, which it accepts only under a maintainer's
# signature, and only when its binary equals the release binary.
FROM base AS caddy-build
COPY caddy/build.sh caddy/allowed_signers caddy/google-linux-signing-key.pub /
RUN --mount=type=bind,source=rhel.repo,target=/etc/yum.repos.d/rhel.repo --mount=type=secret,id=entitlement_certificate --mount=type=secret,id=entitlement_key bash /build.sh


# build-and-publish.sh builds this stage as its own image and runs seal.sh in it, without a network,
# around each signature that KMS makes.
FROM base AS sealing-tools
RUN --mount=type=bind,source=rhel.repo,target=/etc/yum.repos.d/rhel.repo --mount=type=secret,id=entitlement_certificate --mount=type=secret,id=entitlement_key dnf install -y --setopt=install_weak_deps=False systemd-ukify systemd-boot-unsigned pesign nss-tools binutils
COPY seal.sh /seal.sh


# install.sh installs AWS's latest CLI release, which it accepts only under AWS's signature.
# operator-tools.sh builds this stage as its own image, without an entitlement, and runs entitlement.sh
# in it, which reads the entitlement the operator-tools stage's dnf step needs.
FROM base AS aws-cli
COPY aws-cli/install.sh aws-cli/aws-cli.pub /
RUN bash /install.sh


# operator-tools.sh tags the aws-cli stage localhost/aws-cli, builds this stage alone, and runs each
# operator script in it, so the scripts take every tool from signed sources. initdb and pg_ctl are
# in PGDG's directory.
FROM localhost/aws-cli AS operator-tools
COPY tailscale/tailscale.repo postgresql/pgdg.repo /etc/yum.repos.d/
COPY tailscale/RPM-GPG-KEY-tailscale postgresql/PGDG-RPM-GPG-KEY-AARCH64-RHEL /etc/pki/rpm-gpg/
RUN --mount=type=bind,source=rhel.repo,target=/etc/yum.repos.d/rhel.repo --mount=type=secret,id=entitlement_certificate --mount=type=secret,id=entitlement_key dnf install -y --setopt=install_weak_deps=False bind-utils git-core httpd-tools postgresql17-server tailscale
COPY hash-postgresql-password /hash-postgresql-password
ENV PATH=/usr/pgsql-17/bin:/usr/local/bin:/usr/sbin:/usr/bin


# The COPY below is the one list of the SELinux modules. The Makefile's default target compiles every
# .te in /selinux, and the rootfs stage and setup.sh take every .pp it makes.
FROM base AS selinux-modules
RUN --mount=type=bind,source=rhel.repo,target=/etc/yum.repos.d/rhel.repo --mount=type=secret,id=entitlement_certificate --mount=type=secret,id=entitlement_key dnf install -y --setopt=install_weak_deps=False selinux-policy-devel
COPY caddy/caddy.te caddy/caddy.fc postgresql/postgresql_local.te postgresql/postgresql_local.fc stalwart/stalwart.te stalwart/stalwart.fc tailscale/tailscaled.te tailscale/tailscaled.fc /selinux/
RUN make -C /selinux -f /usr/share/selinux/devel/Makefile


FROM base AS rootfs

COPY --chown=0:0 site/ /usr/share/site/
COPY --chown=0:0 --from=caddy-build /build/caddy /usr/bin/
COPY --chown=0:0 sealed/boot/signed/ /usr/lib/systemd/boot/efi/
# The server tarball stores its binary without the executable bit.
COPY --chown=0:0 --chmod=0755 --from=stalwart /stalwart/stalwart /stalwart/stalwart-cli-aarch64-unknown-linux-gnu/stalwart-cli /usr/bin/
COPY --chown=0:0 --from=stalwart /stalwart/spam-filter-rules.json.gz /usr/share/stalwart/
COPY --chown=0:0 --from=selinux-modules /selinux/*.pp /usr/share/selinux/packages/bootc-sealed-vm/

COPY fstab                  /etc/fstab
COPY var/crypttab           /etc/crypttab
COPY var/50-var.conf        /usr/lib/repart.d/50-var.conf
COPY setup-root-conf.toml   /usr/lib/composefs/setup-root-conf.toml
COPY kargs.d/console.toml   /usr/lib/bootc/kargs.d/console.toml
COPY kargs.d/root-ro.toml   /usr/lib/bootc/kargs.d/root-ro.toml
COPY kargs.d/import-credentials.toml /usr/lib/bootc/kargs.d/import-credentials.toml
COPY kargs.d/algif-aead.toml /usr/lib/bootc/kargs.d/algif-aead.toml
COPY kargs.d/heap.toml      /usr/lib/bootc/kargs.d/heap.toml
COPY kargs.d/page-shuffle.toml /usr/lib/bootc/kargs.d/page-shuffle.toml
COPY kargs.d/panic.toml     /usr/lib/bootc/kargs.d/panic.toml
COPY sysctl.d/kernel-restrictions.conf /usr/lib/sysctl.d/kernel-restrictions.conf
COPY modprobe.d/unused-protocols.conf /usr/lib/modprobe.d/unused-protocols.conf
COPY modules-load.d/vfat.conf /usr/lib/modules-load.d/vfat.conf
COPY caddy/Caddyfile        /etc/caddy/Caddyfile
COPY journald.conf          /etc/systemd/journald.conf
COPY service-restrictions.conf           /usr/lib/systemd/service-restrictions.conf
COPY postgresql/run-as-postgres.conf /usr/lib/systemd/run-as-postgres.conf
COPY stalwart/run-as-stalwart.conf /usr/lib/systemd/run-as-stalwart.conf
COPY postgresql/pgdata.conf /usr/lib/systemd/pgdata.conf
COPY tailscale/wireguard-port.env /usr/lib/systemd/wireguard-port.env
COPY tmpfiles.d/root.conf   /etc/tmpfiles.d/root.conf
COPY nftables.conf          /etc/sysconfig/nftables.conf
COPY postgresql/postgresql-dirs.conf /usr/lib/tmpfiles.d/postgresql-dirs.conf
COPY caddy/caddy-dirs.conf  /usr/lib/tmpfiles.d/caddy-dirs.conf
COPY stalwart/stalwart-dirs.conf /usr/lib/tmpfiles.d/stalwart-dirs.conf
COPY stalwart/config.json   /etc/stalwart/config.json
COPY stalwart/plan.jq       /usr/share/stalwart/plan.jq
COPY containers/policy.json /etc/containers/policy.json
COPY tailscale/tailscale.repo /etc/yum.repos.d/tailscale.repo
COPY tailscale/RPM-GPG-KEY-tailscale /etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale
COPY postgresql/pgdg.repo  /etc/yum.repos.d/pgdg.repo
COPY postgresql/PGDG-RPM-GPG-KEY-AARCH64-RHEL /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-AARCH64-RHEL
COPY containers/bootc-sealed-vm.yaml /etc/containers/registries.d/bootc-sealed-vm.yaml
COPY containers/sigpolicy.toml /usr/lib/bootc/install/sigpolicy.toml
COPY postgresql/postgresql.conf postgresql/pg_hba.conf /etc/postgresql/
COPY postgresql/bootstrap.sql /usr/share/boot-postgresql/

COPY setup.sh boot-config.sh aws-api.sh fetch-parameter.sh ecr-login.sh var/repart-var.sh tailscale/boot-tailscale.sh postgresql/boot-postgresql.sh postgresql/bootstrap.sh stalwart/stalwart-apply.sh /opt/scripts/
COPY boot-config.service modules-disabled.service tailscale/boot-tailscale.service postgresql/boot-postgresql.service postgresql/postgresql.service caddy/caddy.service caddy/caddy.socket stalwart/stalwart.service stalwart/stalwart-apply.service /usr/lib/systemd/system/
COPY boot-config-capabilities.conf /usr/lib/systemd/system/boot-config.service.d/zz-capabilities.conf
COPY stalwart/stalwart-capabilities.conf /usr/lib/systemd/system/stalwart.service.d/zz-capabilities.conf
# The Tailscale RPM owns /usr/lib/systemd/system/tailscaled.service, and a unit in /etc/systemd/system replaces it.
COPY tailscale/tailscaled.service /etc/systemd/system/tailscaled.service
COPY tailscale/nftables-wireguard-port.conf /usr/lib/systemd/system/nftables.service.d/wireguard-port.conf
COPY var/repart-var.conf     /usr/lib/systemd/system/systemd-repart.service.d/repart-var.conf
COPY var/cryptsetup-after-repart.conf /usr/lib/systemd/system/systemd-cryptsetup@var.service.d/after-repart.conf
COPY bootc-fetch-apply-updates-composefs.conf /usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/composefs.conf
COPY bootc-fetch-apply-updates-composefs.conf /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/composefs.conf
COPY bootc-fetch-apply-updates-interval.conf /usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/interval.conf
COPY bootc-fetch-apply-updates-ecr-login.conf /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/ecr-login.conf

RUN --mount=type=bind,source=rhel.repo,target=/etc/yum.repos.d/rhel.repo --mount=type=secret,id=entitlement_certificate --mount=type=secret,id=entitlement_key chmod +x /opt/scripts/* && /opt/scripts/setup.sh


# bootc install computes the composefs digest from the image's layers in container storage, and over
# a multi-layer image that disagrees with the merged tree on some directories' mode and mtime
# (https://github.com/bootc-dev/bootc/issues/2194). One layer holds the whole tree, so the two agree.
FROM scratch AS flattened
COPY --from=rootfs / /
LABEL containers.bootc=1


# build-and-publish.sh tags the flattened stage localhost/flattened, runs seal.sh over it, and then
# builds this stage alone. The UKI's command line carries the composefs digest of the flattened
# stage, which covers every file the image contains outside /boot.
FROM localhost/flattened AS sealed
COPY --chown=0:0 sealed/uki/signed/ /boot/EFI/Linux/
