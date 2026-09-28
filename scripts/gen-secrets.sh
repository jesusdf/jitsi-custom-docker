#!/bin/sh
# Fills the secret-valued variables of a .env file with fresh random values.
#
#     ./scripts/gen-secrets.sh [.env]
#
# Only variables that are present and empty are touched, so running it again
# after adding a new one is safe. To rotate a secret, blank it first.
#
# Rotating TURN_CREDENTIALS invalidates in-flight TURN allocations; clients
# reconnect on their own.

set -eu

ENV_FILE=${1:-.env}

SECRET_VARIABLES='
JICOFO_COMPONENT_SECRET
JICOFO_AUTH_PASSWORD
JVB_AUTH_PASSWORD
TURN_CREDENTIALS
JIGASI_XMPP_PASSWORD
JIGASI_TRANSCRIBER_PASSWORD
'

[ -f "$ENV_FILE" ] || { echo "no such file: $ENV_FILE" >&2; exit 1; }

random_secret() {
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

for name in $SECRET_VARIABLES; do
    if ! grep -q "^$name=$" "$ENV_FILE"; then
        echo "skipping $name (absent or already set)"
        continue
    fi

    secret=$(random_secret)
    sed -i "s|^$name=$|$name=$secret|" "$ENV_FILE"
    echo "generated $name"
done
