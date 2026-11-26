#!/usr/bin/env bash
set -euo pipefail

# operator-tools.sh runs this in the aws-cli stage's image. It writes the entitlement certificate and
# key to /entitlement for the operator-tools stage's dnf step, and first registers with Red Hat while
# Secrets Manager holds no certificate that is still valid.
source "$PWD/build.env"
source "$PWD/region.sh"
source "$PWD/read-secret.sh"
source "$PWD/fetch-secret.sh"

# Every later step needs AWS credentials, which ~/.aws keeps, so a machine without them signs in here.
aws sts get-caller-identity >/dev/null 2>&1 || \
    {
        echo 'The AWS CLI is not signed in. Sign it in from this shell as an identity that can create IAM roles, then exit the shell.' >&2
        bash
        aws sts get-caller-identity >/dev/null
    }

# The Red Hat credentials secret is written after the certificate's, so it shows both exist. Red
# Hat's CDN refuses an expired certificate.
{ aws secretsmanager describe-secret --secret-id "$REDHAT_CREDENTIALS_SECRET" >/dev/null 2>&1 && fetch_secret "$ENTITLEMENT_CERTIFICATE_SECRET" | openssl x509 -checkend 0 -noout >/dev/null; } || \
    {
        # Each build pulls the Red Hat base image with a registry service account, and its dnf steps reach
        # Red Hat's CDN with the entitlement certificate, which registering this container issues. The
        # certificate takes a secret of its own, because the two together exceed a secret's size limit.
        read -rp 'Red Hat registry service account username: ' REDHAT_REGISTRY_USERNAME
        read_secret 'Red Hat registry token' REDHAT_REGISTRY_TOKEN
        echo "The registration takes your Red Hat login, the account's own username and password." >&2
        subscription-manager register --name="$REPOSITORY-build"
        entitlement_certificate_path=$(find /etc/pki/entitlement -name '*.pem' ! -name '*-key.pem')
        entitlement_key_path=$(find /etc/pki/entitlement -name '*-key.pem')
        redhat_credentials=$(jq -n --arg redhat_registry_username "$REDHAT_REGISTRY_USERNAME" --rawfile redhat_registry_token <(printf '%s' "$REDHAT_REGISTRY_TOKEN") --rawfile entitlement_key "$entitlement_key_path" \
            '{$redhat_registry_username, $redhat_registry_token, $entitlement_key}')
        # A stopped run or an expired certificate leaves a secret in place, which takes the new value.
        aws secretsmanager put-secret-value --secret-id "$ENTITLEMENT_CERTIFICATE_SECRET" --secret-string "file://$entitlement_certificate_path" >/dev/null 2>&1 || \
            aws secretsmanager create-secret \
                --name "$ENTITLEMENT_CERTIFICATE_SECRET" \
                --secret-string "file://$entitlement_certificate_path" >/dev/null
        aws secretsmanager put-secret-value --secret-id "$REDHAT_CREDENTIALS_SECRET" --secret-string "file://"<(printf '%s' "$redhat_credentials") >/dev/null 2>&1 || \
            aws secretsmanager create-secret \
                --name "$REDHAT_CREDENTIALS_SECRET" \
                --secret-string "file://"<(printf '%s' "$redhat_credentials") >/dev/null
    }

fetch_secret "$ENTITLEMENT_CERTIFICATE_SECRET" > /entitlement/certificate
fetch_secret "$REDHAT_CREDENTIALS_SECRET" | jq -er .entitlement_key > /entitlement/key
