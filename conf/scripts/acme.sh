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
# Until the first certificate is issued, a self-signed placeholder stands in
# for it so that nginx and coturn can start at all -- and nginx has to be up
# for HTTP-01 to succeed. After issuing, the certificate is installed at
# TLS_CERT_FILE / TLS_KEY_FILE and the containers that hold it open are asked
# to reload.

# -f: ACME_DOMAINS may hold wildcards, which must never match files.
set -euf

SCRIPT_NAME=acme
. /conf/scripts/lib.sh

# The image puts acme.sh on the PATH and keeps its state (account, orders,
# issued certificates) under LE_CONFIG_HOME, which the compose file maps to a
# host directory so a recreated container renews instead of issuing again.
ACME=acme.sh
STATE_DIR=${LE_CONFIG_HOME:-/acme.sh}
WEBROOT=/runtime/acme
RENEWAL_INTERVAL_SECONDS=86400

# A failed order is retried by exiting and letting the restart policy bring
# the container back. Waiting first keeps a misconfiguration from burning
# through the CA's failed-validation limit.
RETRY_AFTER_FAILURE_SECONDS=600


# coturn presents the same certificate, so a TURNS_HOST of its own has to be in
# it too.
certificate_domains() {
    if [ -n "${ACME_DOMAINS:-}" ]; then
        split_list "$ACME_DOMAINS" | tr '\n' ' '
    else
        { split_list "${JITSI_DOMAINS:-}"; dedicated_turns_hosts; } | tr '\n' ' '
    fi
}

primary_domain() {
    certificate_domains | cut -d' ' -f1
}

# Marks TLS_CERT_FILE as the placeholder rather than an issued certificate.
placeholder_marker() {
    printf '%s.placeholder' "$TLS_CERT_FILE"
}


# -----------------------------------------------------------------------------
# Placeholder
# -----------------------------------------------------------------------------
# nginx refuses to load a server block whose certificate is missing, and
# coturn cannot start without one either. A self-signed pair lets both come
# up; the real certificate replaces it as soon as it is issued.

ensure_placeholder() {
    [ -f "$TLS_CERT_FILE" ] && [ -f "$TLS_KEY_FILE" ] && return 0

    mkdir -p "$(dirname "$TLS_CERT_FILE")" "$(dirname "$TLS_KEY_FILE")"
    (
        umask 077
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -nodes -days 7 -subj "/CN=$(primary_domain)" \
            -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" >/dev/null 2>&1
    ) || die "could not create the placeholder certificate"
    touch "$(placeholder_marker)"

    log "placeholder certificate in place until the real one is issued"
}


# -----------------------------------------------------------------------------
# Issuing
# -----------------------------------------------------------------------------

# Returns acme.sh's own status: 0 when a certificate was issued or renewed,
# 2 when the stored one is not due yet -- the normal outcome whenever the
# container is recreated -- and anything else on failure.
request_certificate() {
    domains=$(certificate_domains)
    [ -n "$domains" ] || die "no domains to request"

    # shellcheck disable=SC2086
    set -- $(printf -- '-d %s ' $domains)

    case "$TLS_MODE" in
        acme-http)
            mkdir -p "$WEBROOT"
            set -- --webroot "$WEBROOT" "$@"
            ;;
        acme-dns-azure)
            require_azure_credentials
            set -- --dns dns_azure "$@"
            ;;
    esac

    status=0
    "$ACME" --issue "$@" || status=$?
    return "$status"
}

require_azure_credentials() {
    for name in AZUREDNS_SUBSCRIPTIONID AZUREDNS_TENANTID AZUREDNS_APPID AZUREDNS_CLIENTSECRET; do
        eval "value=\${$name:-}"
        [ -n "$value" ] || die "$name is required when TLS_MODE=acme-dns-azure"
    done
}

# Copies the issued certificate over TLS_CERT_FILE / TLS_KEY_FILE and records
# the reload command, which acme.sh runs now and after every renewal.
install_certificate() {
    "$ACME" --install-cert -d "$(primary_domain)" \
        --key-file       "$TLS_KEY_FILE" \
        --fullchain-file "$TLS_CERT_FILE" \
        --reloadcmd      "touch /runtime/certificate-updated"

    rm -f "$(placeholder_marker)"
    log "certificate installed at $TLS_CERT_FILE"
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
    [ -n "${TLS_CERT_FILE:-}" ] && [ -n "${TLS_KEY_FILE:-}" ] \
        || die "TLS_CERT_FILE and TLS_KEY_FILE are required when TLS_MODE=$TLS_MODE"

    # The account key and the domain keys live here. Nothing else reads them.
    chmod 700 "$STATE_DIR"

    ensure_placeholder

    # acme.sh defaults to ZeroSSL; the stack is documented as Let's Encrypt.
    "$ACME" --set-default-ca --server letsencrypt
    "$ACME" --register-account -m "$ACME_EMAIL" || true

    status=0
    request_certificate || status=$?

    case "$status" in
        0)
            install_certificate
            ;;
        2)
            # Not due. The files on disk are current unless they are the
            # placeholder, which happens when the state survived but
            # conf/certs did not.
            if [ -f "$(placeholder_marker)" ]; then
                install_certificate
            else
                log "certificate on disk is current"
            fi
            ;;
        *)
            warn "issuing failed (acme.sh exit $status); retrying in $RETRY_AFTER_FAILURE_SECONDS seconds"
            sleep "$RETRY_AFTER_FAILURE_SECONDS"
            exit 1
            ;;
    esac

    renew_forever
}

main "$@"
