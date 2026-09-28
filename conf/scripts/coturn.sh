#!/bin/sh
# Runs coturn and picks up renewed certificates.
#
# coturn reads its certificate once, at startup. Rather than rely on a reload
# signal, this script ends the process when the certificate changes and lets
# the restart policy bring it back with the new one.

set -eu

SCRIPT_NAME=coturn
. /conf/scripts/lib.sh

CERTIFICATE_MARKER=/runtime/certificate-updated
POLL_INTERVAL_SECONDS=300


current_marker() {
    [ -f "$CERTIFICATE_MARKER" ] && stat -c %Y "$CERTIFICATE_MARKER" || printf 'none'
}

exit_when_certificate_changes() {
    seen=$(current_marker)

    while sleep "$POLL_INTERVAL_SECONDS"; do
        [ "$(current_marker)" = "$seen" ] && continue

        log "certificate changed; exiting so the restart policy reloads it"
        kill "$1" 2>/dev/null || true
        return
    done
}


main() {
    turnserver -c /runtime/turnserver.conf &
    turnserver_pid=$!

    exit_when_certificate_changes "$turnserver_pid" </dev/null >/dev/null 2>&1 &

    wait "$turnserver_pid"
}

main "$@"
