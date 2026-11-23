# boot-root.sh renders Stalwart's settings from this filter on every boot, and stalwart-apply.sh applies
# them. Each top-level object is one stalwart-cli apply operation, listed parents first.
($mail_user + "@" + $domain) as $mailbox_address |
{"@type": "upsert", "object": "AcmeProvider", "matchOn": ["description"], "value": {"acme": {
    "description": "Let's Encrypt",
    # Caddy forwards http://mail.<DOMAIN>/.well-known/acme-challenge/ to the loopback HTTP listener.
    "challengeType": "Http01",
    "contact": {($acme_email): true},
    # Renewals keep the key that the DANE TLSA record pins (see publish-tlsa.sh).
    "reuseKey": true
  }}},
  {"@type": "upsert", "object": "Domain", "matchOn": ["name"], "value": {"domain": {
    "name": $domain,
    "aliases": ([$mail_alias_domains | scan("[^,\\s]+") | {(.): true}] | add // {}),
    "certificateManagement": {"@type": "Automatic", "acmeProviderId": "#acme", "subjectAlternativeNames": {"mail": true}},
    # provision.sh makes the DKIM key and publishes its record, so the plan declares the signature.
    "dkimManagement": {"@type": "Manual"},
    "dnsManagement": {"@type": "Manual"},
    # Every address at the mail domains, postmaster@ and abuse@ among them, lands in the one mailbox.
    "catchAllAddress": $mailbox_address
  }}},
  # Stalwart signs each message an authenticated client sends from a mail domain.
  {"@type": "upsert", "object": "DkimSignature", "matchOn": ["selector"], "value": {"dkim": {
    "@type": "Dkim1RsaSha256",
    "domainId": "#domain",
    "selector": $dkim_selector,
    "privateKey": {"@type": "File", "filePath": "/run/stalwart/dkim-key"}
  }}},
  {"@type": "upsert", "object": "Account", "matchOn": ["name"], "value": {"user": {
    "@type": "User",
    "name": $mail_user,
    "domainId": "#domain",
    "credentials": {"0": {"@type": "Password", "secret": $mail_password_hash}}
  }}},
  # Only port 25 faces the internet, and tailscale serve terminates TLS for the loopback listeners.
  # Every tailnet client arrives from 127.0.0.1, so tailscale serve sends its tailnet address in a PROXY
  # header, which these listeners require from 127.0.0.1. A failed-login ban locks out that client alone.
  {"@type": "reconcile", "object": "NetworkListener", "matchOn": ["name"], "value": {
    "smtp": {"name": "smtp", "protocol": "smtp", "bind": {"0.0.0.0:25": true}, "overrideProxyTrustedNetworks": {"127.0.0.1": true}},
    "submission": {"name": "submission", "protocol": "smtp", "bind": {"127.0.0.1:587": true}, "useTls": false, "overrideProxyTrustedNetworks": {"127.0.0.1": true}},
    "imap": {"name": "imap", "protocol": "imap", "bind": {"127.0.0.1:143": true}, "useTls": false, "overrideProxyTrustedNetworks": {"127.0.0.1": true}},
    "http": {"name": "http", "protocol": "http", "bind": {"127.0.0.1:9000": true}}
  }},
  # tailscale serve sets X-Forwarded-For to the client's tailnet address, replacing any value the
  # client sent.
  {"@type": "update", "object": "Http", "value": {"clientIpSource": "xForwardedFor"}},
  # Stalwart's default keeps a failed-login ban forever, and the running server has no admin to lift one.
  {"@type": "update", "object": "Security", "value": {"authBanPeriod": 3600000}},
  {"@type": "update", "object": "Imap", "value": {"allowPlainTextAuth": true}},
  # Stalwart advertises Web Push with VAPID (RFC 9749), which mail clients' JMAP push needs, only
  # while the Web Push key is set.
  {"@type": "update", "object": "Jmap", "value": {
    "webPushKey": {"@type": "File", "filePath": "/run/stalwart/web-push-key"},
    "webPushContact": "mailto:postmaster@\($domain)"
  }},
  {"@type": "update", "object": "MtaStageAuth", "value": {
    "saslMechanisms": {"match": {"0": {"if": "local_port == 587", "then": "[plain, login]"}}, "else": "false"}
  }},
  # Stalwart sends no DMARC, SPF, DKIM, or TLS reports, so the VM sends only the mailbox's own mail.
  # Reports about this domain go wherever its _dmarc and _smtp._tls records say.
  {"@type": "update", "object": "DmarcReportSettings", "value": {"aggregateSendFrequency": {"else": "disable"}, "failureSendFrequency": {"else": "false"}}},
  {"@type": "update", "object": "SpfReportSettings", "value": {"sendFrequency": {"else": "false"}}},
  {"@type": "update", "object": "DkimReportSettings", "value": {"sendFrequency": {"else": "false"}}},
  {"@type": "update", "object": "TlsReportSettings", "value": {"sendFrequency": {"else": "disable"}}},
  # The spam filter reads its rule set from the file the image ships. A task is deleted once it
  # runs, so each boot's task loads the rule set of the image that booted.
  {"@type": "update", "object": "SpamSettings", "value": {"spamFilterRulesUrl": "file:///usr/share/stalwart/spam-filter-rules.json.gz"}},
  {"@type": "create", "object": "Task", "value": {"rules": {
    "@type": "SpamFilterMaintenance", "maintenanceType": "updateRules", "status": {"@type": "Pending", "due": "2000-01-01T00:00:00Z"}
  }}},
  # The WebUI bundle carries no signature, so the server neither downloads nor serves it.
  {"@type": "reconcile", "object": "Application", "matchOn": ["description"], "value": {"webui": {
    "description": "Stalwart Web Interface", "enable": false, "resourceUrl": "file:///nonexistent", "urlPrefix": {"/admin": true}
  }}},
  # EC2 blocks outbound port 25, so every message for another domain leaves through Forward Email's
  # relay, which accepts the mailbox's address as the login and as the From address.
  {"@type": "upsert", "object": "MtaRoute", "matchOn": ["name"], "value": {"relay": {
    "@type": "Relay",
    "name": "relay",
    "host": "smtp.forwardemail.net",
    "port": 465,
    "implicitTls": true,
    "authUsername": $mailbox_address,
    "authSecret": {"@type": "File", "filePath": "/run/stalwart/relay-password"}
  }}},
  {"@type": "update", "object": "MtaOutboundStrategy", "value": {
    "route": {"match": {"0": {"if": "is_local_domain(rcpt_domain)", "then": "'local'"}}, "else": "'relay'"},
    # Stalwart's default retries a failed TLS handshake without certificate checks, which would hand
    # the relay password to whoever answers.
    "tls": {"else": "'default'"}
  }},
  # journald captures stdout and forwards it to the serial console.
  {"@type": "reconcile", "object": "Tracer", "matchOn": ["@type"], "value": {"stdout": {"@type": "Stdout", "buffered": false}}},
  {"@type": "update", "object": "SystemSettings", "value": {"defaultHostname": "mail.\($domain)", "defaultDomainId": "#domain"}}
