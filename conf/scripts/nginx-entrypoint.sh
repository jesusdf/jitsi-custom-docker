#!/bin/sh
# Generates the nginx configuration that depends on the deployment: the TLS
# defaults, the 443 splitter, one server block per Jitsi domain, and the
# sub-path routes declared in conf/routes.conf.
#
# Installed as /docker-entrypoint.d/30-jitsi.sh, so the stock nginx image runs
# it before starting nginx.

set -eu

SCRIPT_NAME=nginx
. /conf/scripts/lib.sh

GENERATED=/etc/nginx/generated
ROUTES_FILE=/conf/routes.conf

# The backends nginx talks to. Port 8443 is the HTTPS listener behind the
# splitter; 8444 accepts the PROXY header on coturn's behalf and strips it.
HTTPS_BACKEND_PORT=8443
TURN_BACKEND_PORT=8444


# -----------------------------------------------------------------------------
# Layout
# -----------------------------------------------------------------------------

prepare_directories() {
    rm -rf "$GENERATED"
    mkdir -p "$GENERATED/http" "$GENERATED/stream" /etc/nginx/sites

    # The stock image ships a placeholder server that would answer on port 80.
    rm -f /etc/nginx/conf.d/default.conf

    # Drop-in site files written for a host nginx include snippets straight
    # from /etc/nginx. Publishing them at both paths keeps those files working
    # unchanged.
    for snippet in /etc/nginx/snippets/*.conf; do
        [ -e "$snippet" ] || continue
        cp "$snippet" "/etc/nginx/$(basename "$snippet")"
    done
}


# -----------------------------------------------------------------------------
# TLS defaults
# -----------------------------------------------------------------------------
# Included by every HTTPS server block, including operator drop-ins. It carries
# the listen directive, so a drop-in file never has to know which port the
# splitter forwards to.

generate_tls_defaults() {
    HTTPS_BACKEND_PORT=$HTTPS_BACKEND_PORT \
    render /etc/nginx/snippets/site-defaults.conf.template \
           /etc/nginx/site-defaults.conf \
           HTTPS_BACKEND_PORT NGINX_SSL_PROTOCOLS NGINX_SSL_CIPHERS NGINX_HSTS_MAX_AGE
}


# -----------------------------------------------------------------------------
# Trusted source addresses
# -----------------------------------------------------------------------------
# Generates /etc/nginx/only-trusted-hosts.conf, which a site file includes to
# restrict a location:
#
#     location /admin/ {
#         include /etc/nginx/only-trusted-hosts.conf;
#         ...
#     }
#
# No address is ever built in. They come from TRUSTED_HOSTS, or from a file the
# operator supplies in conf/nginx/snippets/ when the rules are more involved
# than a list.

generate_trusted_hosts() {
    target=/etc/nginx/only-trusted-hosts.conf

    # A supplied file wins: it can express rules a plain list cannot.
    if [ -f "$target" ]; then
        log "using the supplied only-trusted-hosts.conf"
        return 0
    fi

    # Failing closed is deliberate. An allow-list with nothing allowed that let
    # everyone through would silently remove a restriction the site file is
    # asking for, and nothing would look wrong.
    if [ -z "${TRUSTED_HOSTS:-}" ]; then
        printf '# Generated: TRUSTED_HOSTS is empty, so no address is trusted.\ndeny all;\n' > "$target"
        warn "TRUSTED_HOSTS is empty: locations including only-trusted-hosts.conf will deny everyone"
        return 0
    fi

    {
        printf '# Generated from TRUSTED_HOSTS. Edit the variable, not this file.\n'
        split_list "$TRUSTED_HOSTS" | while read -r address; do
            printf 'allow %s;\n' "$address"
        done
        printf 'deny all;\n'
    } > "$target"

    log "trusted hosts: $(split_list "$TRUSTED_HOSTS" | tr '\n' ' ')"
}


# -----------------------------------------------------------------------------
# Port 443 splitter
# -----------------------------------------------------------------------------

generate_stream_config() {
    cat > "$GENERATED/stream/443.conf" <<EOF
# TURN clients announce the ALPN "stun.turn"; browsers announce h2 or
# http/1.1. Anything unrecognised is treated as HTTPS.
map \$ssl_preread_alpn_protocols \$jitsi_443_backend {
    ~\\bstun\\.turn\\b  "127.0.0.1:$TURN_BACKEND_PORT";
    default            "127.0.0.1:$HTTPS_BACKEND_PORT";
}

server {
    listen 443;
    listen [::]:443;

    ssl_preread on;

    # Both backends are told the real client address. Without this the HTTPS
    # server would see 127.0.0.1 for every request, which would silently
    # defeat any IP allow-list.
    proxy_protocol on;
    proxy_pass \$jitsi_443_backend;
}

# coturn cannot read the PROXY header, so this hop consumes it and forwards
# plain TCP. The client address survives in this server's logs but not inside
# coturn, which is a known and accepted limitation.
#
# The backend is named through a variable so that nginx resolves it when a
# connection arrives rather than at startup. That keeps the proxy serving
# HTTPS even when coturn is stopped or has yet to start.
server {
    listen 127.0.0.1:$TURN_BACKEND_PORT proxy_protocol;

    resolver ${STACK_RESOLVER:-127.0.0.11} valid=30s ipv6=off;
    set \$turn_backend "coturn:5349";
    proxy_pass \$turn_backend;
}
EOF
}


# -----------------------------------------------------------------------------
# Plain HTTP
# -----------------------------------------------------------------------------
# Serves ACME challenges and redirects everything else. It listens directly on
# port 80, so it never sees the PROXY header.

# Upstreams are named through variables everywhere, so nginx resolves them per
# request instead of once at startup. Without it, a container that is recreated
# with a different address would keep receiving no traffic until nginx is
# restarted.
generate_resolver() {
    cat > "$GENERATED/http/00-resolver.conf" <<EOF
resolver ${STACK_RESOLVER:-127.0.0.11} valid=30s ipv6=off;
EOF
}

generate_http_redirect() {
    cat > "$GENERATED/http/01-redirect.conf" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /runtime/acme;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
EOF
}


# -----------------------------------------------------------------------------
# Jitsi domains
# -----------------------------------------------------------------------------

generate_jitsi_sites() {
    [ -n "${JITSI_DOMAINS:-}" ] || die "JITSI_DOMAINS is empty"

    output="$GENERATED/http/10-jitsi.conf"
    : > "$output"

    split_list "$JITSI_DOMAINS" | while read -r domain; do
        write_jitsi_server "$domain" >> "$output"
        log "serving $domain"
    done
}

write_jitsi_server() {
    domain=$1

    cat <<EOF
server {
    server_name $domain;

    include /etc/nginx/site-defaults.conf;
    include /etc/nginx/no-robots.conf;

    ssl_certificate     ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};

    # Signalling always goes to the primary domain, so a page served from any
    # of the configured domains has to be allowed to reach it.
    add_header 'Access-Control-Allow-Origin'      '*' always;
    add_header 'Access-Control-Allow-Credentials' 'true' always;
    add_header 'Access-Control-Allow-Headers'     '*' always;
    add_header 'Access-Control-Allow-Methods'     'GET,POST' always;

    set \$web_backend "http://web:80";

    location / {
        proxy_pass \$web_backend;
        include /etc/nginx/proxy-defaults.conf;
        proxy_buffering off;
    }

    location = /http-bind {
        proxy_pass \$web_backend/http-bind\$is_args\$args;
        include /etc/nginx/proxy-defaults.conf;
    }

    location = /xmpp-websocket {
        proxy_pass \$web_backend/xmpp-websocket\$is_args\$args;
        include /etc/nginx/proxy-defaults.conf;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 900s;
    }

    # Addressed by the bridge's JVB_WS_SERVER_ID, which the stack sets to the
    # service name so the address survives container recreation.
    location ~ ^/colibri-ws/(.*)\$ {
        proxy_pass http://jvb:9090/colibri-ws/\$1\$is_args\$args;
        include /etc/nginx/proxy-defaults.conf;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 900s;
    }

    location /branding/ {
        alias /srv/branding/;
        add_header 'Access-Control-Allow-Origin' '*' always;
    }

$(write_routes_for "$domain")
}

EOF
}


# -----------------------------------------------------------------------------
# Sub-path routes
# -----------------------------------------------------------------------------
# conf/routes.conf declares, per domain, which sub-paths are proxied elsewhere:
#
#   <domain>  <path-regex>  <target>  [mirror=<url>,<url>...]
#
# A mirror target receives a copy of the request and its response is discarded,
# which is how one deployment fans a notification out to several backends.

write_routes_for() {
    domain=$1
    [ -f "$ROUTES_FILE" ] || return 0

    mirror_id=0
    strip_comments < "$ROUTES_FILE" | while read -r route_domain path target options; do
        [ "$route_domain" = "$domain" ] || continue

        mirror_id=$(( mirror_id + 1 ))
        write_route "$path" "$target" "$options" "$mirror_id"
    done
}

write_route() {
    path=$1
    target=$2
    options=$3
    mirror_id=$4

    case "$target" in
        redirect:*)
            write_redirect_route "$path" "${target#redirect:}"
            return
            ;;
    esac

    mirror_urls=$(option_value "$options" mirror | tr ',' ' ')
    host_override=$(option_value "$options" host)

    printf '    location ~* %s {\n' "$path"
    printf '        set $route_target "%s";\n' "$target"
    printf '        proxy_pass $route_target;\n'
    printf '        include /etc/nginx/proxy-defaults.conf;\n'
    printf '        proxy_ssl_server_name on;\n'

    # An upstream that serves several tenants needs the name it knows itself
    # by, not the name the browser asked for.
    [ -n "$host_override" ] && printf '        proxy_set_header Host %s;\n' "$host_override"

    index=0
    for url in $mirror_urls; do
        index=$(( index + 1 ))
        printf '        mirror /__mirror_%s_%s;\n' "$mirror_id" "$index"
    done
    printf '    }\n\n'

    index=0
    for url in $mirror_urls; do
        index=$(( index + 1 ))
        printf '    location = /__mirror_%s_%s {\n' "$mirror_id" "$index"
        printf '        internal;\n'
        printf '        set $mirror_target "%s";\n' "$url"
        printf '        proxy_pass $mirror_target$request_uri;\n'
        printf '        include /etc/nginx/proxy-defaults.conf;\n'
        printf '        proxy_ssl_server_name on;\n'
        printf '    }\n\n'
    done
}

# redirect:<status>:<location>
write_redirect_route() {
    path=$1
    status=${2%%:*}
    location=${2#*:}

    printf '    location ~* %s {\n' "$path"
    printf '        return %s %s;\n' "$status" "$location"
    printf '    }\n\n'
}

# Reads `name=value` out of a whitespace separated option list.
option_value() {
    for option in $1; do
        case "$option" in
            "$2"=*) printf '%s' "${option#*=}"; return ;;
        esac
    done
}

strip_comments() {
    sed -e 's/#.*$//' -e '/^[[:space:]]*$/d'
}


# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Certificate renewal
# -----------------------------------------------------------------------------
# The ACME container touches a marker file after installing a new certificate.
# Polling it is enough: certificates change a few times a year.

CERTIFICATE_MARKER=/runtime/certificate-updated
CERTIFICATE_POLL_SECONDS=300

reload_when_certificate_changes() {
    seen=$(certificate_marker_stamp)

    while sleep "$CERTIFICATE_POLL_SECONDS"; do
        [ "$(certificate_marker_stamp)" = "$seen" ] && continue

        seen=$(certificate_marker_stamp)
        log "certificate changed; reloading"
        nginx -s reload || warn "reload failed"
    done
}

certificate_marker_stamp() {
    [ -f "$CERTIFICATE_MARKER" ] && stat -c %Y "$CERTIFICATE_MARKER" || printf 'none'
}


# -----------------------------------------------------------------------------

main() {
    prepare_directories
    generate_tls_defaults
    generate_trusted_hosts
    generate_stream_config
    generate_resolver
    generate_http_redirect
    generate_jitsi_sites

    # Only under an ACME mode, because only then does anything renew the
    # certificate behind nginx's back. With TLS_MODE=files the operator
    # replaces the file and restarts, so a watcher would be a background job
    # that never fires -- and one that keeps this container alive after the
    # script finishes, which would hang a one-shot configuration check.
    case "${TLS_MODE:-files}" in
        acme-*) reload_when_certificate_changes </dev/null >/dev/null 2>&1 & ;;
    esac

    log "configuration generated"
}

main "$@"
