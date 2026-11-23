#!/usr/bin/env bash
set -euo pipefail

dnf install -y --setopt=install_weak_deps=False golang git-core
tag=$(curl -sSf https://api.github.com/repos/caddyserver/caddy/releases/latest | jq -er .tag_name)
git clone -q --depth 1 --branch "$tag" https://github.com/caddyserver/caddy /caddy
# allowed_signers holds the SSH keys Caddy's maintainers sign release tags with.
git -C /caddy -c gpg.ssh.allowedSignersFile=/allowed_signers verify-tag "$tag"

# The release binary names its Go version here and is the build's reference at the end.
mkdir /release
curl -sSfL "https://github.com/caddyserver/caddy/releases/download/$tag/caddy_${tag#v}_linux_arm64.tar.gz" | tar -xz -C /release caddy
go_tarball=$(go version /release/caddy | cut -d' ' -f2).linux-arm64.tar.gz
# The compiler that built the release is the one that reproduces its binary, so the build runs upstream's
# Go of the release's version, which it accepts only under Google's signature. hash -r makes bash find
# go on the new PATH.
curl -sSfL --output-dir /tmp -O "https://go.dev/dl/$go_tarball" -O "https://go.dev/dl/$go_tarball.asc"
gpg --dearmor < /google-linux-signing-key.pub > /tmp/google.gpg
gpgv --keyring /tmp/google.gpg "/tmp/$go_tarball.asc" "/tmp/$go_tarball"
tar -xzf "/tmp/$go_tarball" -C /
export PATH=/go/bin:$PATH CGO_ENABLED=0 GOTOOLCHAIN=local
hash -r

# Caddy's release builds a module that requires Caddy at the tag, inside the checkout, which stamps
# the commit into the binary. .goreleaser.yml holds these steps and flags.
mkdir /caddy/caddy-build
cd /caddy/caddy-build
cp ../cmd/caddy/main.go .
go mod init caddy
go mod edit -require="github.com/caddyserver/caddy/v2@$tag"
go mod tidy
# The module proxy's copy of Caddy must equal the signed checkout, and the tag's go.sum must pin
# every other module the build takes.
module=$(go list -m -f '{{.Dir}}' github.com/caddyserver/caddy/v2)
diff -r --exclude=.git --exclude=caddy-build /caddy "$module"
unpinned=$(grep -vxFf /caddy/go.sum go.sum | grep -v "^github.com/caddyserver/caddy/v2 $tag" || true)
[ -z "$unpinned" ]
go build -trimpath -mod=readonly -ldflags '-s -w' -tags nobadger,nomysql,nopgx -o /build/caddy
# A binary from the signed tag that equals the release binary shows the release came from that tag.
cmp /build/caddy /release/caddy
