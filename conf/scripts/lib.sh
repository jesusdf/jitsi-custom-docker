# Shared helpers for the stack's startup scripts.
#
# Templates use @PLACEHOLDER@ markers rather than ${VAR}, so that nginx's own
# $variables and Lua's string syntax survive substitution untouched.

log()  { printf '[%s] %s\n' "${SCRIPT_NAME:-stack}" "$*" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# Splits a comma, space or tab separated list into one item per line, dropping
# empties.
#
# The trailing newline matters: `while read` discards a final line that has
# none, which would silently drop the last item of every list.
split_list() {
    printf '%s\n' "$1" | tr ',\t ' '\n\n\n' | sed '/^$/d'
}

# Escapes a value so it can be used as a sed replacement.
escape_replacement() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# render TEMPLATE OUTPUT PLACEHOLDER...
#
# Copies TEMPLATE to OUTPUT, replacing every @PLACEHOLDER@ with the value of
# the environment variable of the same name. A placeholder whose variable is
# unset becomes an empty string.
render() {
    template=$1
    output=$2
    shift 2

    [ -f "$template" ] || die "template not found: $template"

    script=''
    for name in "$@"; do
        eval "value=\${$name:-}"
        script="$script;s|@$name@|$(escape_replacement "$value")|g"
    done

    sed "${script#;}" "$template" > "$output"
}

# Converts an IPv4 CIDR block into the "first-last" form coturn expects.
#   subnet_to_range 172.31.250.0/24  ->  172.31.250.0-172.31.250.255
subnet_to_range() {
    cidr=$1
    prefix=${cidr#*/}
    base=$(ipv4_to_int "${cidr%/*}")
    size=$(( 1 << (32 - prefix) ))
    network=$(( base - (base % size) ))

    printf '%s-%s' \
        "$(int_to_ipv4 "$network")" \
        "$(int_to_ipv4 "$(( network + size - 1 ))")"
}

ipv4_to_int() {
    IFS=. read -r a b c d <<EOF
$1
EOF
    printf '%s' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

int_to_ipv4() {
    n=$1
    printf '%s.%s.%s.%s' \
        "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" \
        "$(( (n >> 8) & 255 ))"  "$(( n & 255 ))"
}

# True when the value is one of the accepted affirmative spellings.
is_enabled() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}
