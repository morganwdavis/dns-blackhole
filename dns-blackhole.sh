#!/bin/sh
#
# dns-blackhole.sh - Manages a BIND DNS blackhole
#
# Usage:
#   dns-blackhole.sh <on|off|status|update> [config_file]
#
# See https://www.morgandavis.net/post/simple-dns-blackhole/
#

set -eu

#
# Support functions
#

missing_config() {
    echo "Missing config '$1'." >&2
    exit 1
}

fetch_file() {
    url="$1"
    out="$2"
    if command -v fetch >/dev/null 2>&1; then
        fetch -q -m -T "$fetch_timeout" -o "$out" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl --silent --show-error --max-time "$fetch_timeout" --output "$out" "$url"
    else
        echo "Neither fetch nor curl found. Cannot fetch files." >&2
        exit 1
    fi
}

make_zone() {
    printf '; [built by %s]\n\n' "$0"
    printf '$TTL    %d\n\n' 604800
    printf '@%*sIN%*sSOA%*slocalhost. root.localhost. (\n' 13 "" 5 "" 4 ""
    printf '%*s%d   ; Serial\n' 28 "" "$timestamp"
    printf '%*s%d   ; Refresh\n' 32 "" 604800
    printf '%*s%d   ; Retry\n' 33 "" 86400
    printf '%*s%d   ; Expire\n' 31 "" 2419200
    printf '%*s%d ) ; Minimum\n\n' 32 "" 604800
    printf '%*sIN%*sNS%*s%s.\n' 14 "" 5 "" 5 "" "$dns_server_hostname"
}

command_named() {
    cmd="$1"
    if command -v service >/dev/null 2>&1; then
        service named "$cmd"
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl "$cmd" named
    else
        echo "Cannot $cmd named service." >&2
        exit 1
    fi
}

get_symlink_target() {
    link="$1"
    if [ -L "$link" ]; then
        basename "$(readlink "$link" 2>/dev/null || echo '')"
    else
        echo ''
    fi
}

#
# Update zone data
#
do_update() {
    # Initialize empty files if they don't exist
    for f in blocked_hosts allowed_hosts; do [ -f "$f" ] || touch "$f"; done

    # Create temporary working directory if it doesn't exist
    [ ! -d "$tmp_dir" ] && mkdir -p "$tmp_dir"

    echo "Fetching master host list..."
    output="$tmp_dir/master_hosts_list"
    attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        if [ "$attempt" -gt 0 ]; then
            echo "Fetch failed. Retrying in $retry_seconds seconds..." >&2
            sleep "$retry_seconds"
        fi

        if fetch_file "$master_host_list_url" "$output"; then
            break
        fi

        attempt=$((attempt + 1))
    done

    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "Fetch failed after $max_attempts attempts. Giving up." >&2
        exit 1
    fi

    echo "Optimizing hosts list..."
    cat "$output" blocked_hosts |
        sed -e 's/^[[:space:]]*//' |
        grep -v '^#' |
        awk '{print $2}' |
        grep -Ev '^(0\.0\.0\.0|localhost)$' |
        grep -v '^$' |
        sort -u >"$tmp_dir/optimized_hosts"

    echo "Excluding allowed hosts..."
    sort allowed_hosts | comm -23 "$tmp_dir/optimized_hosts" - >"$tmp_dir/blocked_hosts"

    timestamp=$(date +%s)

    echo "Installing enabled/disabled RPZ zone files..."
    make_zone >"$tmp_dir/$disabled_rpz"
    make_zone >"$tmp_dir/$enabled_rpz"
    sed 's/.*/& CNAME ./' "$tmp_dir/blocked_hosts" >>"$tmp_dir/$enabled_rpz"
    cp "$tmp_dir/$enabled_rpz" "$tmp_dir/$disabled_rpz" "$named_zone_files_dir/"
    chmod 644 "$named_zone_files_dir/$enabled_rpz"

    if [ ! -f "$named_includes_dir/dns-blackhole.zone" ]; then
        echo "Building included zone file..."
        {
            echo 'zone "rpz" {'
            echo '    type master;'
            echo '    file "dns-blackhole.rpz";'
            echo '};'
        } >"$named_includes_dir/dns-blackhole.zone"
    fi

    if [ "$debug" = "0" ]; then
        echo "Cleaning up..."
        rm "$tmp_dir"/* && rmdir "$tmp_dir"
    fi

    if [ ! -L "$switch_symlink" ]; then
        switch_blocker "off"
    fi
}

#
# Switch DNS blackhole state
#
switch_blocker() {
    cd "$named_includes_dir"
    tgt=$enabled_rpz
    if [ ! -f "$tgt" ]; then
        echo "Not ready to turn $1 yet. Perform an update first."
        exit 1
    fi
    [ "$1" = off ] && tgt="$disabled_rpz"
    [ "$(readlink "$switch_symlink" 2>/dev/null || echo)" = "$tgt" ] && {
        echo "DNS blackhole already $1."
        exit 0
    }
    ln -sf "$tgt" "$switch_symlink"
    echo "DNS blackhole switched $1."
}

#
# Show status
#
show_status() {
    cd "$named_includes_dir"
    target="$(get_symlink_target "$switch_symlink")"
    if [ "$target" = "$enabled_rpz" ]; then
        echo "DNS blackhole is on."
    else
        echo "DNS blackhole is off."
    fi
}

#
# Main
#

cd "$(dirname "$0")"
opt="${1:-}"
cfg="${2:-dns-blackhole.conf}"

case "$opt" in
on | off | status | update) ;;
*)
    echo "Usage: $0 <on|off|status|update> [config_file]" >&2
    exit 1
    ;;
esac

[ -f "$cfg" ] || {
    echo "Config file '$cfg' not found." >&2
    exit 1
}

# shellcheck source=/dev/null
. "$cfg"

[ -n "$dns_blackhole_dir" ] || missing_config "dns_blackhole_dir"
[ -n "$named_includes_dir" ] || missing_config "named_includes_dir"
[ -n "$named_zone_files_dir" ] || missing_config "named_zone_files_dir"
[ -n "$tmp_dir" ] || missing_config "tmp_dir"
[ -n "$dns_server_hostname" ] || missing_config "dns_server_hostname"
[ -n "$fetch_timeout" ] || missing_config "fetch_timeout"
[ -n "$retry_seconds" ] || missing_config "retry_seconds"
[ -n "$max_attempts" ] || missing_config "max_attempts"
[ -n "$master_host_list_url" ] || missing_config "master_host_list_url"
[ -n "$debug" ] || missing_config "debug"

for d in "$dns_blackhole_dir" "$named_includes_dir" "$named_zone_files_dir"; do
    [ -d "$d" ] || {
        echo "Directory '$d' missing." >&2
        exit 1
    }
done

cd "$dns_blackhole_dir"

switch_symlink="dns-blackhole.rpz"
enabled_rpz="dns-blackhole-enabled.rpz"
disabled_rpz="dns-blackhole-disabled.rpz"

cmd="restart"

case "$opt" in
status)
    show_status
    cmd="status"
    ;;
update) do_update ;;
on | off) switch_blocker "$opt" ;;
esac

command_named "$cmd"
