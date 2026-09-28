#!/bin/sh
# Issues and renews the stack's certificate with acme.sh.
#
# Three modes, selected with TLS_MODE:
#
#   files           Nothing to do. The operator supplies the certificate.
#   acme-http       HTTP-01. The challenge is written where nginx serves
#                   /.well-known/acme-challenge/. No wildcards.
#   acme-dns-azure  DNS-01 against Azure DNS. Wildcards supported.
#
# After issuing, the certificate is installed at TLS_CERT_FILE / TLS_KEY_FILE
# and the containers that hold it open are asked to reload.

set -eu

SCRIPT_NAME=acme
. /conf/scripts/lib.sh

ACME=/root/.acme.sh/acme.sh
WEBROOT=/runtime/acme
RENEWAL_INTERVAL_SECONDS=86400


request_certificate() {
    domains=$(certificate_domains)
    [ -n "$domains" ] || die "no domains to request"

    # shellcheck disable=SC2086
    set -- $(printf -- '-d %s ' $domains)

    case "$TLS_MODE" in
        acme-http)
            mkdir -p "$WEBROOT"
            "$ACME" --issue --webroot "$WEBROOT" "$@"
            ;;
        acme-dns-azure)
            require_azure_credentials
            "$ACME" --issue --dns dns_azure "$@"
            ;;
    esac
}

certificate_domains() {
    if [ -n "${ACME_DOMAINS:-}" ]; then
        split_list "$ACME_DOMAINS" | tr '\n' ' '
    else
        split_list "${JITSI_DOMAINS:-}" | tr '\n' ' '
    fi
}

require_azure_credentials() {
    for name in AZUREDNS_SUBSCRIPTIONID AZUREDNS_TENANTID AZUREDNS_APPID AZUREDNS_CLIENTSECRET; do
        eval "value=\${$name:-}"
        [ -n "$value" ] || die "$name is required when TLS_MODE=acme-dns-azure"
    done
}

install_certificate() {
    primary=$(certificate_domains | cut -d' ' -f1)

    "$ACME" --install-cert -d "$primary" \
        --key-file       "$TLS_KEY_FILE" \
        --fullchain-file "$TLS_CERT_FILE" \
        --reloadcmd      "touch /runtime/certificate-updated"
}

# acme.sh renews when the certificate is close to expiry and does nothing
# otherwise, so a daily pass is enough.
renew_forever() {
    while true; do
        sleep "$RENEWAL_INTERVAL_SECONDS"
        "$ACME" --cron || warn "renewal pass failed; will retry tomorrow"
    done
}


main() {
    case "${TLS_MODE:-files}" in
        files)
            log "TLS_MODE=files: certificates are managed outside the stack"
            exit 0
            ;;
        acme-http|acme-dns-azure)
            ;;
        *)
            die "unknown TLS_MODE: $TLS_MODE"
            ;;
    esac

    [ -n "${ACME_EMAIL:-}" ] || die "ACME_EMAIL is required when TLS_MODE=$TLS_MODE"
    "$ACME" --register-account -m "$ACME_EMAIL" || true

    request_certificate
    install_certificate
    log "certificate installed at $TLS_CERT_FILE"

    renew_forever
}

main "$@"
