# bootc-sealed-vm

This repository builds a sealed, immutable bootc image of RHEL that runs personal web and mail services on one AWS Graviton VM. Every boot renders its configuration from AWS Parameter Store. `provision.sh` puts every deployment-specific setting and secret the VM needs into Parameter Store. Caddy serves the public static site, and the MTA-STS policy at `mta-sts.<DOMAIN>`, on port 443. Stalwart receives mail for `<DOMAIN>` on port 25 and sends the mailbox's outbound mail, signed with its own DKIM key, through Forward Email's SMTP relay. Tailscale exposes PostgreSQL and Stalwart's IMAP, submission, JMAP, CalDAV, CardDAV, and WebDAV to the tailnet alone.

The image's only deployment-specific values are the site it serves, PostgreSQL settings sized for `m9g.medium`, and the region of the ECR registry it pulls and verifies updates from. The same image therefore deploys to any AWS account in that region on a Graviton instance type.

Filesystem layout follows the conventions of bootc's [composefs backend](https://bootc.dev/bootc/bootc-composefs.7.html).

## Why bootc

The VM's OS is a container image. `Containerfile` and `setup.sh` define the whole OS, Podman builds it, and each build signs and publishes it like any other image. The image is ordinary RHEL with systemd units and shell scripts, so changing it takes no Nix expressions, and the VM pulls its own updates, so shipping a change takes no SSH-driven tool like Ansible.

On RHEL bootc, the build or the VM checks a signature on five links: Red Hat signs the base image, each package repository signs its packages, Stalwart's release workflows attest its server and CLI, a Caddy maintainer signs the release tag Caddy is built from, and each build signs the published image (see [Base Image](#architecture) and [Signed Images](#architecture)). Each build also signs the boot chain with a Secure Boot key that the VM's firmware trusts alone (see [OS Integrity](#hardening)). Fedora bootc cannot match that chain, because Fedora publishes its bootc base images unsigned ([releng#10624](https://forge.fedoraproject.org/releng/tickets/issues/10624)), and the signing server that would sign them runs only in staging ([infra#13655](https://forge.fedoraproject.org/infra/tickets/issues/13655)).

Fedora CoreOS signs its packages and OS updates, but its boot chain stops verifying at the kernel. On GCE it boots through a shim that Microsoft's UEFI CA signs, which the firmware's default keys trust ([fedora-coreos-tracker#346](https://github.com/coreos/fedora-coreos-tracker/issues/346)). GRUB then loads the initramfs from `/boot` outside any signature ([Unified Kernel Support](https://fedoraproject.org/wiki/Changes/Unified_Kernel_Support_Phase_1)), and the boot checks no digest of its composefs root ([Composefs](https://docs.fedoraproject.org/en-US/fedora-coreos/composefs/)). Its TPM2 root encryption binds to no PCR by default and to PCR 7 at most, because the kernel command line changes with every update ([Storage](https://docs.fedoraproject.org/en-US/fedora-coreos/storage/)). Someone holding the disk can therefore change the initramfs, and the TPM still unlocks the root. Here the firmware trusts only this repository's certificate, the signed unified kernel image (UKI) covers the initramfs and the command line that pins the root's digest, and `/var` unlocks only under a UKI the PCR key signed. The comparison holds once RHEL's bootc enforces that digest (see [OS Integrity](#hardening)). Fedora CoreOS plans the same sealed images ([fedora-coreos-tracker#1719](https://github.com/coreos/fedora-coreos-tracker/issues/1719)).

The image puts the integrity of the running system first, and NixOS and Guix put build reproducibility first. Both pin every source by hash and sign the binaries their caches serve, and Guix also checks that each commit it pulls carries an authorized developer's signature ([Channel Authentication](https://guix.gnu.org/manual/en/html_node/Channel-Authentication.html)). Both therefore verify package provenance more completely than this image. Neither seals its boot by default. NixOS signs its kernel and initramfs only through [Lanzaboote](https://github.com/nix-community/lanzaboote), a project outside nixpkgs, and protects its store with dm-verity only in images built with [`repart-verity-store.nix`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/image/repart-verity-store.nix) and replaced whole. Guix System boots through GRUB, extlinux, or U-Boot, and none of them runs a signed UKI. Ansible configures a conventional host over SSH, so the host keeps its distribution's boot chain and a login path, and it drifts between runs.

Nothing logs into the VM, so the running system changes only through a signed image update (see [Signed Images](#architecture) and [Automatic Updates](#architecture)) or a Parameter Store change. Because `/etc` resets on every boot (see [Stateless Configuration](#architecture)), each boot reproduces what the image and Parameter Store state.

The cost is latency. Every change to this repository, a one-line configuration edit included, ships as a build that the VM applies on its own update schedule. To recover from bad state, reboot the VM or reprovision it (see [FAQ](#faq)).

## Architecture

- **Stateless Configuration**: `setup-root-conf.toml` makes `/etc` transient, so every boot starts it fresh from the image's copy. Boot scripts then render the files that derive from Parameter Store. Persistent state lives under `/var`, on its own encrypted partition (see [Hardening](#hardening)).
- **Base Image**: `Containerfile` builds upon `registry.redhat.io/rhel10/rhel-bootc:latest`. The build pulls it with a Red Hat registry service account. `containers/build-policy.json` makes the build accept it only when its sigstore signature verifies against Red Hat's release key 3. RHEL's BaseOS and AppStream repositories in `rhel.repo` supply every RHEL package, and Red Hat's CDN serves them only to the subscription's entitlement certificate, which each dnf step mounts for its own run. `setup.sh` upgrades the base image's packages, so each build carries the errata Red Hat published since its last base image. It then installs Tailscale from Tailscale's RHEL repository and PostgreSQL 17 from the PostgreSQL project's PGDG repository. dnf verifies RHEL's packages against Red Hat's release key and the others against their repositories' GPG keys, which the image ships. A build stage builds Caddy from its latest release tag, because RHEL doesn't ship it. `caddy/build.sh` accepts the tag only under a Caddy maintainer's SSH signature, takes the release's Go version from go.dev only under Google's GPG signature, and accepts its build only when it equals the release binary byte for byte. The site and CV come from `main` in the website's CodeCommit repository, which `WEBSITE_REPOSITORY` names and the build instance clones under its role, as it clones this repository. The build runs the website's `Containerfile`, which pins its Hugo, Alpine, and Fedora base images by digest, so each build runs the bytes the website's commit names. The build checks no signature on those images. Alpine's and Fedora's package managers verify the packages the site's build adds, and Hugo fetches the publications' MODS documents from the ACL Anthology. Stalwart's server and CLI come from their latest release tarballs, which the build accepts only when `gh attestation verify` confirms each came from its repository's release workflow at that release's tag. GitHub serves a public repository's attestations without a login, so the build holds no GitHub credential. The rule set of Stalwart's spam filter comes from the latest `stalwartlabs/spam-filter` release, which carries no signature or attestation, and its lookups download IP-to-ASN data and lookup lists at runtime. The image accepts that unsigned data because a bad rule set or list can at worst misfile or reject mail.
- **Builds**: Each build runs on its own EC2 instance, which a Step Functions state machine starts from the `bootc-build` launch template and which terminates when the build ends. The instance boots Fedora's cloud image, whose kernel gives Podman 6 and bootc's composefs install cgroups v2. It clones `main` from this repository's and the website's CodeCommit repositories and runs `build-and-publish.sh`, which builds the arm64 image with Podman, signs it, pushes it to ECR, and replaces the VM AMI, which `provision.sh` creates the VM from. The image installs itself with `bootc install to-disk` onto the instance's second volume, whose snapshot becomes the VM AMI, and the VM AMI carries the Secure Boot certificate the VM's firmware trusts (see [OS Integrity](#hardening)). The signing keys stay in KMS (see [Signing Keys](#hardening)). A build starts on each push to `main` in either CodeCommit repository, and daily from an EventBridge rule, so package updates ship without commits. A newer build terminates one in progress. Each build instance uploads its log to the `bootc-build-logs-<account>` bucket (see [How do I start a build or read its log?](#how-do-i-start-a-build-or-read-its-log)).
- **Automatic Updates**: The running VM pulls updates from this repository's private ECR repository through the `bootc-fetch-apply-updates` systemd timer, which fetches every hour, and reboots to apply each one (see [Secret Handling](#hardening) for the registry login and [What if an update fails to boot?](#what-if-an-update-fails-to-boot)).
- **Signed Images**: The build has KMS sign each pushed image with the image key and stores the signature in the registry as a sigstore attachment. `containers/policy.json` makes the VM accept an update only when its signature verifies against the key's public half from Parameter Store.

## Deployment & Configuration

`provision.sh`, `build.env`, and `containers/policy.json` hold the non-secret settings, and `provision.sh` prompts for secrets. It puts the Caddy settings, the MTA-STS policy, the mail settings, the password hashes, Stalwart's DKIM and Web Push keys and its relay password, a single-use Tailscale auth key, and the image key's public half into Parameter Store under `/bootc-vm/`. `entitlement.sh` stores the Red Hat registry token and the RHEL entitlement certificate and key in Secrets Manager for the build (see [Prepare the Project](#1-prepare-the-project)). KMS creates the Secure Boot key, the PCR key, and the image key (see [Signing Keys](#hardening)). The secrets every boot reads travel in one encrypted `pending-secrets` parameter, which `remove-boot-secrets.sh` removes once the VM has stored them (see [Verify PostgreSQL Access](#3-verify-postgresql-access) and [Secret Handling](#hardening)). After the removal, Parameter Store still records the public halves of the DKIM and Web Push keys the VM holds, and the SHA-256 of its relay password.

### 1. Prepare the Project
Install Podman and git, and connect the machine to your tailnet. `reserve-address.sh`, `provision.sh`, and `publish-tlsa.sh` each run themselves through `operator-tools.sh`, in a container of the operator-tools image, so the three scripts take only bash and Podman from the machine's own packages. Every run builds that image from two stages of `Containerfile`. The `aws-cli` stage adds AWS's latest CLI release to the signed base image, and `aws-cli/install.sh` accepts the release only under the signature of the key AWS publishes in the CLI's user guide. The `operator-tools` stage adds packages from the RHEL, PGDG, and Tailscale repositories the VM's image uses (see [Base Image](#architecture)). The container shares the machine's network, drives its tailscaled through the socket, and reads AWS credentials from `~/.aws`. `./operator-tools.sh` alone opens a shell in the operator-tools image at the repository root, and every `aws` command in this README runs in such a shell.

`operator-tools.sh` logs Podman in to `registry.redhat.io` with your registry service account while Podman is logged out, and pulls the base image under `containers/build-policy.json`, as the build does. Between the two stages it runs `entitlement.sh`. While the AWS CLI is signed out, `entitlement.sh` opens a shell for you to sign it in as an identity that can create IAM roles. It then reads the entitlement certificate that the operator-tools stage's dnf step needs from Secrets Manager. While Secrets Manager holds no valid certificate, it asks for the registry service account's username and token, which each build uses to pull the base image, and `subscription-manager` prompts for your Red Hat login to register a `<REPOSITORY>-build` system. It stores the username, the token, and the system's entitlement key in the `bootc-build` secret and the certificate in the `bootc-build-entitlement-certificate` secret. Service accounts stay valid until you regenerate or delete them (see [FAQ](#faq)).

`provision.sh` places the VM in the account's default VPC.

The build needs RHEL's full repositories, which the no-cost [Red Hat Developer Subscription for Individuals](https://developers.redhat.com/articles/faqs-no-cost-red-hat-enterprise-linux) covers on up to 16 systems. Red Hat attaches it to an account when the account creates a Developer Sandbox from the Red Hat Developer site, and starting a RHEL download may not attach it. Check that [console.redhat.com/subscriptions/inventory](https://console.redhat.com/subscriptions/inventory) lists it before provisioning. Then create a registry service account at https://access.redhat.com/terms-based-registry/. The service account's page shows its username, in the form `1234567|name`, and its token. Podman's login and `entitlement.sh` ask for both.

deSEC must serve the zones that hold `<DOMAIN>` and every `WEBSITE_ALIAS_DOMAINS` and `MAIL_ALIAS_DOMAINS` domain. `reserve-address.sh`, `provision.sh`, and `publish-tlsa.sh` each ask for a deSEC token-management token and write DNS through a token they create for that run, named `reserve-address`, `provision`, and `publish-tlsa`, whose policies deny every record except the ones the run sets ([Provision the VM](#2-provision-the-vm) lists `provision.sh`'s). The run deletes its token on exit and leaves the token-management token. Create the token-management token in deSEC's web interface, named `token-management`, with only the token-management switch on, before you reserve the address. Revoke it once `publish-tlsa.sh` has set the TLSA record, and create a new one for each later run of the three scripts.

Reserve the VM's address before provisioning:
```bash
./reserve-address.sh mail.<DOMAIN>
```
The script allocates an Elastic IP address tagged `bootc-ip` while none exists, points the A record of `mail.<DOMAIN>` at it, and makes `mail.<DOMAIN>` the address's reverse DNS record, which AWS sets only once the A record resolves. A rerun changes nothing.

EC2 blocks outbound TCP 25, so Stalwart sends every message for another domain through [Forward Email](https://forwardemail.net)'s SMTP relay on port 465, and Forward Email's servers deliver it. Outbound SMTP takes one of Forward Email's paid plans. Add `<DOMAIN>` to the account, and publish the DKIM record and the `fe-bounces` CNAME record that its outbound SMTP setup page shows, beside a `_dmarc` record. Once Forward Email approves the domain, create the alias `<MAIL_USER>@<DOMAIN>` there and generate its password, which `provision.sh` asks for. MX stays with the VM, so Forward Email handles outbound mail alone, and it accepts only that alias as the From address.

In the Tailscale admin console, enable HTTPS certificates for the tailnet. Under Policy file management, turn on "Prevent edits in the admin console": `tailscale/policy.json` is the tailnet's policy file, and every build instance applies it before it builds. The instance authenticates through a Tailscale federated credential that trusts only the tokens AWS signs for the build instances' role and may only change the policy file, so no Tailscale secret is stored anywhere. `provision.sh` creates the credential while its `tailscale-policy-client-id` parameter is missing, replacing any credential a failed run left behind, and turns on the account's outbound identity federation, which lets AWS sign those tokens.

The policy file lets every tailnet device reach `tag:vm` on TCP 443, 465, 993, and 5432, and lets only `tag:operator` reach it on TCP 25 (see [Provision the VM](#2-provision-the-vm)). Run `provision.sh` and `publish-tlsa.sh` on a machine in the tailnet. `provision.sh` adds `tag:operator` to that machine's tags while it lacks the tag, after it applies the policy that names the tag.

Then edit the settings at the top of `provision.sh`, `WEBSITE_REPOSITORY` in `build.env`, and the registry's region in `containers/policy.json`:
- `VM_INSTANCE_TYPE`, `VM_DISK_SIZE`: The VM's instance type and the size of its EBS boot volume in GiB, passed to `aws ec2 run-instances`. The root partition takes the 30 GiB that `build-and-publish.sh` passes to `bootc install`, and `/var` takes the rest. The image is arm64, so `VM_INSTANCE_TYPE` must be a Graviton type.
- `BUILD_INSTANCE_TYPE`, `BUILD_FEDORA_RELEASE`: The build instances' type, and the Fedora release whose newest cloud image they boot.
- `DOMAIN`: Primary domain Caddy serves (fills `{$DOMAIN}` in the Caddyfile).
- `ACME_EMAIL`: Email address for Caddy's and Stalwart's ACME accounts.
- `WEBSITE_ALIAS_DOMAINS`: Comma-separated domains that permanently redirect to the same path on `https://<DOMAIN>`.
- `MAIL_USER`: Local part of the one Stalwart mailbox, which also takes every other address at the mail domains.
- `MAIL_ALIAS_DOMAINS`: Comma-separated domains whose mail Stalwart delivers to the same mailbox as `<DOMAIN>`'s, or `,` for none.
- `TAILNET`: The tailnet's MagicDNS suffix, such as `tail1234.ts.net`, which Stalwart's discovery URLs name.
- `WEBSITE_REPOSITORY`: The name of the website's CodeCommit repository, whose `main` the build builds into the served site (see [Base Image](#architecture)).
- `containers/policy.json`: Its `*.dkr.ecr.<region>.amazonaws.com` key names the region of the registry whose images the VM accepts. `region.sh` reads the region from it for every script that runs the AWS CLI.

The script prompts for these secrets without echoing them:
- deSEC token-management token, through which the run creates its own `provision` token, and which is stored nowhere (see [Prepare the Project](#1-prepare-the-project)).
- Tailscale API access token, which the script asks for only while the federated credential, this machine's `tag:operator`, or the VM is missing, and which is stored nowhere. When it creates the VM, it creates through this token a single-use, pre-authorized `tag:vm` auth key that expires after an hour, which the first boot logs in with. Under Tailnet Lock, this machine pre-signs the key with `tailscale lock sign`, so the VM signs its own node key and the coordination server cannot substitute one. Later boots reconnect with the node key in tailscaled's state on `/var`, which never expires because the node is tagged, so the VM keeps working after both the auth key and the access token expire. Revoke the access token after the run.
- Relay password, the password of the Forward Email alias `<MAIL_USER>@<DOMAIN>`, which Stalwart logs in to the relay with. Use the password Forward Email generates, because Parameter Store keeps its SHA-256.
- PostgreSQL `experiments` password and mail password. `provision.sh` hashes these in the operator-tools container, with its PostgreSQL and `htpasswd`, so only the hashes reach Parameter Store. It asks for the PostgreSQL password only while the VM is missing, because only the first boot reads its hash.

`provision.sh` keeps each secret and password hash out of argv, the environment, shell history, and local disk.

### 2. Provision the VM
```bash
./provision.sh <website checkout>
```
This script creates the VM, or updates the existing VM's parameters and reboots it when a value changed or secrets are pending, so the VM reads them at its next boot. A rerun with unchanged settings and secrets changes nothing. It adds a secret to `pending-secrets` only when the VM lacks its current value: the mail password's hash when the VM's Stalwart rejects the typed password over the tailnet, the DKIM key and the Web Push key when Parameter Store records no public half for them, and the relay password when its SHA-256 differs from the one Parameter Store records. While the VM does not answer over the tailnet, a rerun hashes the mail password again and reboots the VM. It also deploys `infrastructure.yaml` as the `bootc` CloudFormation stack, which holds the other resources that remain when the VM is deleted: the two CodeCommit repositories and the ECR repository, the build's launch template, state machine, and daily and push rules, the bucket for the build log, the IAM roles, the `bootc-vm` security group, and a network interface. The security group admits TCP 80, 443, and 25, and UDP on the port in `tailscale/wireguard-port.env` for direct WireGuard paths. Each VM attaches the network interface, which holds the `bootc-ip` address that `reserve-address.sh` allocated.

Each role grants only what its holder does. The build instances' role reads the build's secrets and parameters, signs with the three keys, pushes the image, and replaces the VM AMI. The VM's role reads its own parameters and pulls its image.

KMS creates each of the three keys whose alias is missing: `alias/bootc-secureboot`, `alias/bootc-pcr`, and `alias/bootc-image`. When the `secureboot-certificate` parameter is missing, OpenSSL creates the Secure Boot certificate around the Secure Boot key's public half. Later runs reuse every key. The argument is the path to the website's checkout, which `operator-tools.sh` mounts read-only in the container. When either CodeCommit repository has no `main` branch, the script pushes that checkout's `main` there, and each push starts a build. The newer build ends the older one. It waits for the VM AMI before creating the VM, and stops when a build ends without one. To push later changes, add this repository's CodeCommit repository as a remote:
```bash
git config credential.https://git-codecommit.<region>.amazonaws.com.helper '!aws codecommit credential-helper $@'
git config credential.https://git-codecommit.<region>.amazonaws.com.UseHttpPath true
git remote add codecommit https://git-codecommit.<region>.amazonaws.com/v1/repos/bootc-sealed-vm
```

In the website's checkout, run the same commands with `<WEBSITE_REPOSITORY>` in place of `bootc-sealed-vm`. Pushes to either remote run the credential helper through the machine's own AWS CLI.

Before creating the VM, the script sets these records through deSEC's API. Each PATCH replaces the whole record list of every name and type it sets, so no stale value stays beside a new one.
- A records for `<DOMAIN>`, `mail.<DOMAIN>`, `mta-sts.<DOMAIN>`, and every `WEBSITE_ALIAS_DOMAINS` domain, pointing at the `bootc-ip` address. The address survives VM and stack deletion, so the records stay valid across reprovisioning.
- CAA records for the same names, which let only Let's Encrypt issue their certificates, through the HTTP-01 and TLS-ALPN-01 challenges that Caddy and Stalwart answer.
- For `<DOMAIN>` and every `MAIL_ALIAS_DOMAINS` domain: an MX record naming `mail.<DOMAIN>`.
- For `<DOMAIN>`: the DKIM key's public half at `bootc._domainkey.<DOMAIN>`, and the SPF value `v=spf1 include:spf.forwardemail.net -all`, which names Forward Email's servers as the domain's only senders. The apex TXT set keeps its other values, such as site verifications. The mailbox sends as `<DOMAIN>` alone.
- For every `MAIL_ALIAS_DOMAINS` domain: `v=spf1 -all`, so it receives mail and nobody can send as it.
- For every other `WEBSITE_ALIAS_DOMAINS` domain: a null MX and `v=spf1 -all`, so it receives no mail and nobody can send as it.
- The `_mta-sts.<DOMAIN>` TXT record, whose id hashes the MTA-STS policy that `provision.sh` renders, so senders fetch the policy again whenever it changes.
- When it creates the VM, it deletes the `_25._tcp.mail.<DOMAIN>` TLSA record, because the new VM's Stalwart generates a new key.

The script leaves `_dmarc` and `_smtp._tls` records and Forward Email's two records alone, so DMARC and TLS reports keep going wherever they point. Stalwart itself sends no DMARC, SPF, DKIM, or TLS reports to other domains, so the VM sends only the mailbox's own mail.

`publish-tlsa.sh` sets the `_25._tcp.mail.<DOMAIN>` TLSA record for DANE. It reads Stalwart's certificate over the tailnet on port 25, because many networks block outbound 25, and pins its key only when Let's Encrypt's chain validates it for `mail.<DOMAIN>`. Otherwise it exits with an error and changes nothing, so a passing network fault leaves a valid record in place. It reads the domain and tailnet from the VM's parameters and prompts only for a deSEC token-management token. Run it from the `tag:operator` machine once Stalwart has its certificate. Stalwart reuses the key across renewals, so the record stays valid until a reprovision creates a new `/var`.

### 3. Verify PostgreSQL Access
After it creates or updates the VM, `provision.sh` runs `remove-boot-secrets.sh`, which waits until PostgreSQL answers over the tailnet. PostgreSQL answers only after `boot-config.sh` stored the pending secrets and the Tailscale login and the PostgreSQL bootstrap succeeded. Until then, every boot stores the pending secrets again and retries the login and the bootstrap. The script then removes `pending-secrets`, `tailscale-auth-key`, and `postgresql-experiments-hash` from Parameter Store. It waits while any of them remains, so a run stopped during the wait finishes the removal the next time. Under Tailnet Lock, `provision.sh` then signs the VM's node key from this machine and removes the signing key the pre-signed auth key carried, which locks out any other node that key signed. If the wait does not end, see [FAQ](#faq). Once the script finishes, connect with psql as in [Access](#access). When psql reports `password authentication failed for user "experiments"`, see [FAQ](#faq).

## Access

`boot-tailscale.sh` logs the node in. Its `tailscale serve` configuration forwards tailnet TCP 5432 to local PostgreSQL and terminates TLS for Stalwart's loopback listeners: tailnet 993 for IMAP, 465 for submission, and HTTPS 443 for JMAP, CalDAV, CardDAV, and WebDAV. Tailnet 25 passes through to Stalwart's SMTP listener (see [Provision the VM](#2-provision-the-vm)). `tailscale/policy.json` decides which clients reach those ports (see [Prepare the Project](#1-prepare-the-project)). Stalwart sees each client's tailnet address, which `tailscale serve` passes in a PROXY header on 993, 465, and 25 and in `X-Forwarded-For` on 443. Stalwart bans an address for an hour after 100 failed logins in a day, so a client retrying a wrong password locks out only itself.

**PostgreSQL**:
```bash
psql 'postgresql://experiments@bootc-sealed-vm.<TAILNET>:5432/experiments'
```

**WebDAV**: `tailscaled` terminates TLS under the node's MagicDNS name. It obtains the Let's Encrypt certificate on the first request and renews it, and the certificate survives reboots and image updates. Stalwart serves files under the mail login. Configure an `rclone` remote named `webdav` (`type = webdav`, `vendor = other`, `url = https://bootc-sealed-vm.<TAILNET>/dav/file/<MAIL_USER>@<DOMAIN>/`) using `MAIL_USER` and the mail password, then access it via:
```bash
rclone ls webdav:
```
Stalwart replaces each upload's modification time with the upload time, and `vendor = other` makes rclone compare sizes only, so a sync skips an edit that keeps a file's size the same.

**Mail, calendars, and contacts**: Sign in as `MAIL_USER` with the mail password. Point a mail client at `bootc-sealed-vm.<TAILNET>` with IMAP on 993 and SMTP submission on 465, both with TLS. CalDAV and CardDAV clients discover their collections from `https://bootc-sealed-vm.<TAILNET>/`, and JMAP clients from `https://bootc-sealed-vm.<TAILNET>/.well-known/jmap`. IMAP advertises that JMAP URL through `JMAPACCESS`, and JMAP offers EmailPush and Web Push with VAPID, which Stalwart signs with a P-256 key that `provision.sh` generates once and keeps across runs.

## Reprovisioning

Terminating the VM also deletes its EBS boot volume, and with it everything under `/var`: the PostgreSQL data, WebDAV files, mail, calendars, and contacts, Caddy's and Stalwart's certificates, and Tailscale state. Copy off anything you need first. To reprovision the VM:
1. **Delete the old node from the Machines page of the Tailscale admin console**, so the new VM can register under the `bootc-sealed-vm` MagicDNS name.
2. After `source region.sh` in the repository root, terminate the existing VM with `aws ec2 terminate-instances --instance-ids <id>`.
3. Run `./provision.sh <website checkout>`.
4. Verify PostgreSQL access again (see [Verify PostgreSQL Access](#3-verify-postgresql-access)).
5. Once Stalwart has its certificate, run `./publish-tlsa.sh` so the TLSA record pins the new VM's key.

## FAQ

### What if `provision.sh` keeps waiting for PostgreSQL?

If the wait in [Verify PostgreSQL Access](#3-verify-postgresql-access) does not end, run `source region.sh` in the repository root, then read the console output with `aws ec2 get-console-output --latest --instance-id <id>` and reboot the VM with `aws ec2 reboot-instances --instance-ids <id>`. A Tailscale login that has not succeeded an hour after the VM was created never will, because the auth key has expired, so terminate the VM and run `provision.sh` again.

### What if psql rejects the `experiments` password after provisioning?

If psql reports `password authentication failed for user "experiments"` for the password you meant to set, the bootstrap succeeded with a mistyped one. Every boot skips the bootstrap once the PostgreSQL data directory exists (see `boot-config.sh`), so a reboot keeps the mistyped password. If you know the mistyped password, connect with it (see [Access](#access)) and run psql's `\password`, which hashes the new password before sending it. A role can change its own password. Otherwise you can recover only by reprovisioning, because `postgres` authenticates only by peer on the VM's local socket (see `postgresql/pg_hba.conf`) and nothing logs into the VM (see [Why bootc](#why-bootc)). Reprovisioning deletes everything under `/var` (see [Reprovisioning](#reprovisioning)). Until you write to PostgreSQL or WebDAV or receive mail, `/var` holds nothing you need.

### How do I start a build or read its log?

Run this from the repository root. Nothing logs in to a build instance, so the log it uploads when it ends is the only record of a failed build, and the bucket keeps the latest build's log alone.
```bash
source region.sh
build_start_arn=$(aws cloudformation describe-stacks --stack-name bootc --query "Stacks[0].Outputs[?OutputKey=='BuildStartArn'].OutputValue" --output text)
aws stepfunctions start-execution --state-machine-arn "$build_start_arn"
account_id=$(aws sts get-caller-identity --query Account --output text)
aws s3 cp "s3://bootc-build-logs-$account_id/build.log" -
```

### How do I replace the Red Hat registry token?

Regenerate the token, or create a new service account, at https://access.redhat.com/terms-based-registry/. Then run this from the repository root in an interactive shell. It handles the token as `provision.sh` handles its secrets (see [Prepare the Project](#1-prepare-the-project)).
```bash
source region.sh
(read -rsp 'Red Hat registry token: ' REDHAT_REGISTRY_TOKEN && echo && aws secretsmanager get-secret-value --secret-id bootc-build --query SecretString --output text | \
    jq --rawfile token <(printf '%s' "$REDHAT_REGISTRY_TOKEN") '.redhat_registry_token = $token' | aws secretsmanager put-secret-value --secret-id bootc-build --secret-string file:///dev/stdin)
```
A new service account also has a new username. Store it the same way, with `--arg username '<USERNAME>'` and `.redhat_registry_username = $username` in the jq step.

### How do I renew the RHEL entitlement?

The entitlement certificate lasts a year, and the Developer Subscription renews yearly on the Red Hat Developer site. Once the stored certificate has expired, the next run of `reserve-address.sh`, `provision.sh`, or `publish-tlsa.sh` asks for the registry service account again and registers a new `<REPOSITORY>-build` system. Then delete the old one from the systems inventory at console.redhat.com, which counts it among the subscription's 16 systems.

### How do I pick up a change to the MTA-STS policy?

Edit the policy in `provision.sh` and run it again. It updates the `mta-sts-policy` parameter and the `_mta-sts.<DOMAIN>` id, and it reboots the VM, whose `boot-config.sh` renders the policy from that value on every boot.

### What if Stalwart rejects the mail password?

`stalwart-apply.sh` sets the mail password from the hash `boot-config.sh` stored on every boot, so a password changed from a mail client lasts only until the next boot. To change it, run `provision.sh` again with the new password. Stalwart rejects it, so the script hashes it and reboots the VM (see [Provision the VM](#2-provision-the-vm)). Change the password only this way: `provision.sh` would accept a password set from a mail client, because Stalwart accepts it until the next boot, and the VM would then return to the stored hash.

### How do I rotate the image key?

After `source region.sh` in the repository root, delete the key's alias with `aws kms delete-alias --alias-name alias/bootc-image` before reprovisioning. `provision.sh` then has KMS create a new key and puts its public half among the new VM's parameters. Start a build before the VM's next fetch (see [How do I start a build or read its log?](#how-do-i-start-a-build-or-read-its-log)), because the VM rejects the published image until the new key has signed one.

### How do I rotate the Secure Boot or PCR key?

Delete both keys' aliases and the certificate, then reprovision:
```bash
source region.sh
aws kms delete-alias --alias-name alias/bootc-secureboot
aws kms delete-alias --alias-name alias/bootc-pcr
aws ssm delete-parameter --name /bootc-build/secureboot-certificate
```
`provision.sh` has KMS create both keys again, creates a new certificate, deregisters the VM AMI, and starts a build whose VM AMI carries the new certificate. A running VM cannot take a new key: EC2 sets an instance's firmware keys from its AMI at launch, so the firmware would reject an update signed with a new Secure Boot key, and `/var` would stay sealed under a new PCR key.

### What if an update fails to boot?

bootc's composefs backend keeps the previous deployment as a second boot entry, but without boot counting, systemd-boot keeps choosing the failed one, and choosing the other takes the boot menu, which nothing reaches. Read the console output to find the cause, fix it in the repository, and reprovision.

## Hardening

### Boot Chain and Disk

- **OS Integrity**: The image is sealed. Each build makes a UKI that holds the kernel, the initramfs, and a command line naming the composefs digest of the image's root filesystem, which covers every OS file outside `/boot`. The initramfs mounts the root only when its composefs image matches that digest, and the kernel checks each file against its fs-verity digest whenever it reads it. The build has KMS sign the UKI and systemd-boot with the Secure Boot key, and the VM AMI carries its certificate as the platform key, key exchange key, and signature database, so the VM's firmware boots nothing else. The root and `/sysroot` mount read-only. RHEL's bootc 1.17.1 lets unsigned metadata on the disk decide whether the initramfs enforces fs-verity and which composefs image it mounts, so someone holding the disk can boot a modified root under the signed UKI, and the NitroTPM still unlocks `/var`. bootc's fix ([bootc#2629](https://github.com/bootc-dev/bootc/pull/2629)) reaches the image with the first RHEL bootc release that carries it. The UKIs built before that stay signed, so reprovisioning with new keys then retires them (see [How do I rotate the Secure Boot or PCR key?](#how-do-i-rotate-the-secure-boot-or-pcr-key)).
- **Disk Encryption**: On first boot, `systemd-repart` creates `/var` in the free space of the disk that holds the root partition, as a LUKS2 volume whose key is sealed to the VM's NitroTPM (see `var/repart-var.sh`). The NitroTPM releases the key only while PCR 7 shows Secure Boot enforcing this repository's certificate, and while PCR 11 matches values that the PCR key signed for one of this repository's UKIs. The signatures cover PCR 11 only until the boot reaches `sysinit.target`, which comes after the unlock, so no process that starts later can unseal the key. A copy or snapshot of the disk stays unreadable without this VM's NitroTPM, and a boot with Secure Boot turned off leaves `/var` locked. The NitroTPM is a virtual device that the Nitro System provides ([NitroTPM](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nitrotpm.html)), so AWS's host software holds whatever the key is sealed under. The encryption protects `/var` from other holders of the account's volumes and snapshots, not from AWS.
- **Signing Keys**: The Secure Boot key, the PCR key, and the image key exist only in KMS, which signs on request and never releases a private half. Only the build instances' role may sign with them, so a compromised build can sign only while it runs, and CloudTrail records each signature. `seal.sh` prepares what each Secure Boot and PCR signature covers in a container without a network, and `build-and-publish.sh` has KMS sign it. Each build instance's instance metadata service (IMDS) answers only the instance itself, so the build's containers cannot take the role's credentials.

### Host

- **Host Isolation**: `m9g` instances run on Graviton5, whose hosts carry AWS's Nitro Isolation Engine, a small Rust kernel at the hypervisor's privilege level. The engine alone maps the VM's memory, holds its saved registers, and programs the IOMMU for its devices. The rest of the Nitro Hypervisor runs deprivileged beside the guests and manages them through the engine's hypercalls. AWS reports machine-checked Isabelle/HOL proofs that a model of the engine keeps each guest's memory and registers confidential and intact through VM creation, vCPU management, and memory management. Device management, live update, live migration, and micro-architectural side channels lie outside the proofs ([whitepaper](https://d1.awsstatic.com/onedam/marketing-channels/website/aws/en_US/whitepapers/compliance/nitro-isolation-engine-whitepaper.pdf), June 2026). The engine protects the VM's memory against other tenants and against a fault in the rest of the hypervisor. It rests on trusting AWS: the host's attestation goes to AWS alone, the NitroTPM's attestation document covers only the VM's own PCRs, the Nitro Cards read and write the VM's memory to serve its disk and network, and AWS replaces the engine while the VM runs. Like `/var`'s key, the VM's memory is protected by AWS, not from it.
- **Control-Flow Protection**: Graviton gives the VM control-flow protection. On `m9g.medium` the kernel detects pointer authentication and Branch Target Identification (BTI), and no Memory Tagging Extension. RHEL builds its kernel to sign return addresses with pointer authentication, and builds its userspace packages with both, so a corrupted return address or a jump into the middle of a function faults instead of running.

### Network

- **Network**: `nftables` loads a static default-drop ruleset. The ruleset admits inbound traffic only on the web ports, SMTP on 25, and the WireGuard UDP port, plus DHCP replies and rate-limited ICMP echo requests, and it drops every TCP packet that carries IP options. It admits outbound traffic only for DHCP, DNS, NTP, HTTP(S), the relay's port 465 from Stalwart's user alone, Tailscale ports, and ICMP. It drops IPv6 on every path, loopback included. Only root can reach IMDS, which hands out the instance role's credentials. The `bootc-vm` security group holds the same inbound allowlist outside the VM. `tailscaled` runs in userspace networking mode, so no tunnel interface exists and it never alters the VM's nftables rules.

### Services

- **Removed Services**: `setup.sh` removes the SSH server and client and deletes `/etc/ssh`. It also removes NFS, Red Hat's registration and reporting tools (`subscription-manager`, `insights-client`, and `rhc`), and bootupd with its GRUB payload, and masks the serial console login.
- **Service Restrictions**: Every unit this repository ships runs under the shared restrictions in `service-restrictions.conf`, which empties the capability bounding set. Each unit adds only its own differences, such as its writable paths. Stalwart and `boot-config` list the capabilities they keep in a `zz-capabilities.conf` drop-in.
- **Least Privilege**: Caddy holds no capability, because systemd binds ports 80 and 443 through `caddy.socket` and passes Caddy the sockets. It runs as the unprivileged `caddy` user, confined in its own SELinux domain, `caddy_t`, which `caddy/caddy.te` defines. The domain may bind and connect to HTTP ports, resolve DNS, read its configuration, the site, the MTA-STS policy, and the system certificates, and manage its state in `/var/lib/caddy`. `postgresql/postgresql_local.fc` gives PGDG's server binaries the labels RHEL's policy gives their `/usr/bin` counterparts, so PostgreSQL runs confined as `postgresql_t`. RHEL's policy lets systemd enter that domain only without `NoNewPrivileges`, so `postgresql_local.te` adds that transition. Stalwart retains `CAP_NET_BIND_SERVICE` and runs confined in `stalwart_t`, which `stalwart/stalwart.te` defines. The domain may bind SMTP, IMAP, and HTTP ports, connect to SMTP and HTTP ports, resolve DNS, read its configuration, the spam filter's rule set, and the system certificates, and manage its store in `/var/lib/stalwart`. `tailscaled` runs unprivileged as a `DynamicUser` service in `tailscaled_t`, which `tailscale/tailscaled.te` defines. The domain may bind UDP ports, connect to TCP ports, resolve DNS, read the system certificates, and manage its state, cache, and socket directories. A build stage compiles the four modules with RHEL's `selinux-policy-devel`.

### Kernel

- **Kernel Restrictions**: `kargs.d/algif-aead.toml` keeps the kernel from registering `AF_ALG`'s AEAD socket interface. `kargs.d/heap.toml` makes the kernel zero heap memory when it allocates and frees it. `kargs.d/page-shuffle.toml` shuffles the page allocator's free lists at boot. `kargs.d/panic.toml` reboots the VM ten seconds after a kernel panic, and RHEL's kernel panics on an oops, so a kernel fault ends in a fresh boot. `sysctl.d/kernel-restrictions.conf` disables user namespaces and `kexec`, limits `ptrace` to `CAP_SYS_PTRACE`, hardens the BPF JIT, stops line-discipline autoloading, and disables io_uring. `modprobe.d/unused-protocols.conf` refuses to load the modules for protocols the VM never speaks, IPsec among them. Once every service has started, `modules-disabled.service` stops the kernel from loading any further module until the next boot. `modules-load.d/vfat.conf` loads the ESP's filesystem before that, so bootc can still write an update's UKI.
- **Writable Storage**: No unit can execute a file it wrote. `fstab` mounts `/var` with `nodev`, `nosuid`, and `noexec`, and `service-restrictions.conf` makes `/tmp`, `/var/tmp`, `/dev/shm`, and `/run` non-executable for every unit this repository ships. Each unit with a writable directory under `/run` adds it to its own `NoExecPaths=`.

### Secrets

- **Secret Handling**: Secrets pass through Parameter Store only until the VM has read them, as encrypted parameters that the VM's instance role reads. `boot-config.sh` moves the pending secrets into `/var/lib/boot-config`, which only root can enter, on the encrypted `/var`, and renders them from there on every boot. `boot-config.sh` renders the hash of the PostgreSQL password into a `pghash`-group file, which `boot-postgresql.sh` opens as postgres and feeds to `bootstrap.sh` on stdin. The VM stores no registry credential: before each update fetch, `ecr-login.sh` obtains a twelve-hour registry password as the instance role and renders it root-only into `/etc/ostree/auth.json`. `boot-config.sh` copies the DKIM and Web Push keys and the relay password into `/run/stalwart`, which only the `stalwart` group can enter and which `stalwart.fc` labels for `stalwart_t` alone. Stalwart keeps its settings in its store, so each boot `stalwart-apply.sh` starts it in recovery mode, which runs no mail services, with an admin secret it generates for that run alone. It applies the plan that `boot-config.sh` renders, then stops the server. The server `stalwart.service` starts holds no admin account or secret, and Stalwart's unsigned WebUI stays disabled.

## Repository Layout

### Build & Provisioning
- `Containerfile`: Multi-stage build definition.
- `setup.sh`: Applies the rootfs stage's build-time mutations.
- `provision.sh`: Provisioning script (see [Deployment & Configuration](#deployment--configuration)).
- `operator-tools.sh`: Builds the operator-tools image and runs a script or a shell in it (see [Prepare the Project](#1-prepare-the-project)).
- `entitlement.sh`: Reads the entitlement for the operator-tools image's dnf step, and registers with Red Hat while none is stored (see [Prepare the Project](#1-prepare-the-project)).
- `aws-cli/`: Installer for AWS's signed CLI release, with AWS's public key (see [Prepare the Project](#1-prepare-the-project)).
- `reserve-address.sh`: Allocates the VM's address and sets its reverse DNS record (see [Prepare the Project](#1-prepare-the-project)).
- `publish-tlsa.sh`: Sets the DANE TLSA record from Stalwart's live certificate (see [Provision the VM](#2-provision-the-vm)).
- `remove-boot-secrets.sh`: Removes the secrets from Parameter Store once the VM has read them (see [Verify PostgreSQL Access](#3-verify-postgresql-access)).
- `desec.sh`: Helpers for deSEC's API, which `reserve-address.sh`, `provision.sh`, and `publish-tlsa.sh` source (see [Prepare the Project](#1-prepare-the-project)).
- `read-secret.sh`: The secret prompt, which `entitlement.sh` and the three scripts that source `desec.sh` source (see [Prepare the Project](#1-prepare-the-project)).
- `fetch-this-machine.sh`: The `tag:operator` test, which `provision.sh` and `publish-tlsa.sh` source.
- `build.env`: The names `provision.sh` shares with `build-and-publish.sh` or the stack: the VM AMI, this repository's ECR and CodeCommit repositories, the website's CodeCommit repository, the key aliases, the build's secrets, the build instances' name, the build log's key, and the two parameter paths.
- `region.sh`: Sets the AWS region for every script that runs the AWS CLI (see [Prepare the Project](#1-prepare-the-project)).
- `fetch-secret.sh`: The Secrets Manager read that `entitlement.sh` and `build-and-publish.sh` source.
- `infrastructure.yaml`: The CloudFormation template for the resources that remain when the VM is deleted (see [Provision the VM](#2-provision-the-vm)).
- `build-and-publish.sh`: The build that each build instance runs (see [Builds](#architecture)).
- `seal.sh`: Prepares and attaches the Secure Boot and PCR signatures inside the sealing-tools image (see [Signing Keys](#hardening)).
- `tailscale/apply-policy.sh`: Applies `tailscale/policy.json` to the tailnet from each build instance (see [Prepare the Project](#1-prepare-the-project)).
- `rhel.repo`: RHEL's BaseOS and AppStream repositories (see [Base Image](#architecture)).

### Top-Level Scripts & Services
- `boot-config.{sh,service}`: Runs as root on each boot and renders configuration files from Parameter Store and the stored secrets (see [Secret Handling](#hardening)).
- `boot-config-capabilities.conf`: `boot-config`'s capability drop-in (see [Hardening](#hardening)).
- `aws-api.sh`, `fetch-parameter.sh`: Helpers the boot scripts use to call AWS as the VM's instance role and to read values from Parameter Store.
- `ecr-login.sh`, `bootc-fetch-apply-updates-ecr-login.conf`: Obtain the registry password before each update fetch (see [Secret Handling](#hardening)).
- `bootc-fetch-apply-updates-composefs.conf`: Lets the update timer and service run on bootc's composefs backend (see [Automatic Updates](#architecture)).
- `bootc-fetch-apply-updates-interval.conf`: Sets the update timer's fetch interval (see [Automatic Updates](#architecture)).

### Service Directories
- `caddy/`: `Caddyfile` (static, with `{$VAR}` placeholders filled from Parameter Store), `caddy.service` and `caddy.socket`, the `caddy.te` and `caddy.fc` policy module (see [Hardening](#hardening)), `caddy-dirs.conf`, and `build.sh` with the keys it checks signatures against, `allowed_signers` and `google-linux-signing-key.pub` (see [Base Image](#architecture)).
- `postgresql/`: Server configurations (`postgresql.conf`, `pg_hba.conf`), `pgdg.repo` and `PGDG-RPM-GPG-KEY-AARCH64-RHEL` (see [Base Image](#architecture)), `postgresql.service`, the bootstrap (`boot-postgresql.{sh,service}`, `bootstrap.sh`, `bootstrap.sql`), `run-as-postgres.conf` (unit settings both PostgreSQL units share), `pgdata.conf` (the data directory for `boot-config` and both PostgreSQL units), the `postgresql_local.te` and `postgresql_local.fc` policy module (see [Hardening](#hardening)), and `postgresql-dirs.conf`.
- `stalwart/`: `config.json` (the RocksDB store's path), `plan.jq` (every other setting, rendered from Parameter Store), `stalwart-apply.{sh,service}` (see [Secret Handling](#hardening)), `stalwart.service`, `run-as-stalwart.conf` (unit settings both Stalwart units share), `stalwart-capabilities.conf` and the `stalwart.te` and `stalwart.fc` policy module (see [Hardening](#hardening)), and `stalwart-dirs.conf`.
- `tailscale/`: `tailscale.repo` and `RPM-GPG-KEY-tailscale` (see [Base Image](#architecture)), `tailscaled.service`, which replaces the RPM's unit, and the `tailscaled.te` and `tailscaled.fc` policy module (see [Hardening](#hardening)), `boot-tailscale.{sh,service}` (see [Access](#access)), `wireguard-port.env` (the WireGuard port that `tailscaled`, `nftables`, and `provision.sh` read), and `nftables-wireguard-port.conf` (the `nftables.service` drop-in that passes that port to `nft`), and `policy.json` (the tailnet's policy file).

### Configuration
- `var/`: The encrypted `/var` partition (see [Hardening](#hardening)): `50-var.conf` (its `systemd-repart` definition), `repart-var.sh` and `repart-var.conf` (the `systemd-repart.service` drop-in that runs it on the disk that holds the root partition), `crypttab`, and `cryptsetup-after-repart.conf` (orders the unlock after `systemd-repart`).
- `setup-root-conf.toml`: The initramfs's `/etc` and `/var` mounts (see [Stateless Configuration](#architecture)).
- `kargs.d/`: Kernel arguments that the build puts on the UKI's command line.
- `sysctl.d/kernel-restrictions.conf`, `modprobe.d/unused-protocols.conf`, `modules-load.d/vfat.conf`, `modules-disabled.service`: Kernel settings, the module blocklist, and the unit that stops module loading (see [Hardening](#hardening)).
- `nftables.conf`, `fstab`, `journald.conf`: Standalone configuration files.
- `service-restrictions.conf`: Shared systemd service restrictions (see [Hardening](#hardening)).
- `tmpfiles.d/root.conf`: Masks systemd's `root.conf` tmpfiles entry.
- `containers/`: Signature policy for image updates (see [Signed Images](#architecture)). `policy.json` accepts local `containers-storage` images, so the build can install the image it just built from local storage. `bootc-sealed-vm.yaml` turns on sigstore attachments, so the build and the VM read image signatures from the registry. `sigpolicy.toml` makes `bootc install` enforce the signature policy. `build-policy.json` and `SIGSTORE-redhat-release3` make the build verify the base image (see [Base Image](#architecture)).
- `hash-postgresql-password/`: SCRAM-SHA-256 hasher for PostgreSQL passwords, which the operator-tools image carries and `provision.sh` runs (see [Prepare the Project](#1-prepare-the-project)).
