#!/usr/bin/env bash
set -euo pipefail

# Installs AWS's latest CLI release, which it accepts only under the signature of the key AWS
# publishes in the CLI's user guide. The base image has no unzip, and Python's zipfile drops the
# executable bits, which the chmod restores.
installer=awscli-exe-linux-aarch64.zip
curl -sSf -o "/tmp/$installer" "https://awscli.amazonaws.com/$installer"
curl -sSf -o "/tmp/$installer.sig" "https://awscli.amazonaws.com/$installer.sig"
gpg --dearmor < /aws-cli.pub > /tmp/aws-cli.gpg
gpgv --keyring /tmp/aws-cli.gpg "/tmp/$installer.sig" "/tmp/$installer"
python3 -m zipfile -e "/tmp/$installer" /tmp
chmod +x /tmp/aws/dist/aws /tmp/aws/dist/aws_completer
bash /tmp/aws/install
rm -r /tmp/aws "/tmp/$installer" "/tmp/$installer.sig" /tmp/aws-cli.gpg
