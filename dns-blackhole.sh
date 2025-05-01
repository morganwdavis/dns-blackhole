#!/bin/sh
#
# dns-blackhole.sh - Manages a BIND DNS blackhole using Response Policy Zones (RPZ)
# https://www.morgandavis.net/post/simple-dns-blackhole/
#
# See below for options and usage details.

usage_and_exit() {
    cat >&2 <<EOF
Usage:
  $(basename "$0") [OPTIONS] <on|off|status|update>

Options:
  -c config_file    Specify an alternate config file (default: dns-blackhole.conf)
  -k                Keep temporary working files (skip cleanup after update)
  -q                Quiet mode: suppress progress messages
  -r                Restart 'named' instead of reloading the RPZ
  on|off            Turn the blackhole on or off
  status            Report blackhole and 'named' status
  update            Fetch new blocked hosts data and rebuild zone files

See also: https://www.morgandavis.net/post/simple-dns-blackhole/
EOF
    exit 1
}

#
# Support functions
#

error_exit() {
    echo "$@" >&2
    exit 1
}

msg() {
    if [ "$quiet" -eq 0 ]; then
        echo "$@"
    fi
}

missing_config() {
    error_exit "Missing config '$1'."
}

fetch_file() {
    url="$1"
    out="$2"
    if command -v fetch >/dev/null 2>&1; then
        fetch -q -m -T "$fetch_timeout" -o "$out" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl --silent --show-error --max-time "$fetch_timeout" --output "$out" "$url"
    else
        error_exit "Neither fetch nor curl found. Cannot fetch files."
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
        error_exit "Cannot $cmd named service."
    fi
}

command_rndc() {
    if ! command -v rndc >/dev/null 2>&1; then
        error_exit "Error: rndc not found in PATH"
    fi
    command rndc "$@"
}

get_symlink_target() {
    link="$named_zone_files_dir/$switch_symlink"
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

    msg "Fetching master host list..."
    master_list="$tmp_dir/master_hosts_list"
    attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        if [ "$attempt" -gt 0 ]; then
            echo "Fetch failed. Retrying in $retry_seconds seconds..." >&2
            sleep "$retry_seconds"
        fi

        if fetch_file "$master_host_list_url" "$master_list"; then
            break
        fi

        attempt=$((attempt + 1))
    done

    if [ "$attempt" -ge "$max_attempts" ]; then
        error_exit "Failed after $attempt/$max_attempts attempts."
    fi

    msg "Optimizing ..."
    cat "$master_list" "$dns_blackhole_dir/blocked_hosts" |
        sed -e 's/^[[:space:]]*//' |
        grep -v '^#' |
        awk '{print $2}' |
        grep -Ev '^(0\.0\.0\.0|localhost)$' |
        grep -v '^$' |
        sort -u >"$tmp_dir/optimized_hosts"

    msg "Excluding allowed hosts..."
    sort "$dns_blackhole_dir/allowed_hosts" |
        comm -23 "$tmp_dir/optimized_hosts" - >"$tmp_dir/blocked_hosts"

    timestamp=$(date +%s)

    msg "Installing enabled/disabled RPZ zone files..."
    make_zone >"$tmp_dir/$disabled_rpz"
    make_zone >"$tmp_dir/$enabled_rpz"
    sed 's/.*/& CNAME ./' "$tmp_dir/blocked_hosts" >>"$tmp_dir/$enabled_rpz"
    cp "$tmp_dir/$enabled_rpz" "$tmp_dir/$disabled_rpz" "$named_zone_files_dir/"
    chmod 644 "$named_zone_files_dir/$enabled_rpz"
    chmod 644 "$named_zone_files_dir/$disabled_rpz"

    if [ ! -f "$named_includes_dir/$included_zone" ]; then
        msg "Building included zone file..."
        {
            echo 'zone "rpz" {'
            echo '    type master;'
            echo '    file "'$switch_symlink'";'
            echo '};'
        } >"$named_includes_dir/$included_zone"
    fi

    if [ "$keep_temp" -eq 0 ]; then
        msg "Cleaning up..."
        rm "$tmp_dir"/* && rmdir "$tmp_dir"
    fi

    if [ "$(get_symlink_target)" = "" ]; then
        # Create the symlink; defaulting to off
        switch_blackhole "off"
    else
        show_status
    fi
}

#
# Update RPZ zone serial
#
update_serial() {
    timestamp=$(date +%s)
    zone_file=$(get_symlink_target)

    # Set sed in-place flag (GNU is -i alone; BSD is -i '')
    in_place=$(sed --version >/dev/null 2>&1 && echo -i || echo "-i ''")

    eval sed "$in_place" "'s/^\([[:space:]]*\)[0-9]\{1,\}\([[:space:]]*; Serial\)/\1'$timestamp'\2/'" "$named_zone_files_dir/$zone_file"
}

#
# Switch DNS blackhole state
#
switch_blackhole() {
    state="$1"
    tgt=$enabled_rpz
    if [ ! -f "$named_zone_files_dir/$tgt" ]; then
        error_exit "Not ready. Perform an update first."
    fi
    [ "$state" = off ] && tgt="$disabled_rpz"
    [ "$(get_symlink_target)" = "$tgt" ] && {
        msg "DNS blackhole already $state."
        exit 0
    }
    ln -sf "$tgt" "$named_zone_files_dir/$switch_symlink"
    msg "DNS blackhole switched $state."
}

#
# Show status
#
show_status() {
    msg "DNS blackhole is $([ "$(get_symlink_target)" = "$enabled_rpz" ] && echo "on" || echo "off")."
}

#
# Main
#

set -eu

config_file="dns-blackhole.conf"
included_zone="dns-blackhole.zone"
switch_symlink="dns-blackhole.rpz"
enabled_rpz="dns-blackhole-enabled.rpz"
disabled_rpz="dns-blackhole-disabled.rpz"

# Change to the directory where this script resides (resolve symlinks if possible)
if command -v realpath >/dev/null 2>&1; then
    SCRIPT_DIR=$(dirname "$(realpath "$0")")
elif readlink -f "$0" >/dev/null 2>&1; then
    SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
else
    SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
fi
cd "$SCRIPT_DIR"

quiet=0
keep_temp=0
refresh="command_rndc reload rpz"

while getopts "c:kqr" opt; do
    case "$opt" in
    c) config_file=$OPTARG ;;
    k) keep_temp=1 ;;
    q) quiet=1 ;;
    r) refresh="command_named restart" ;;
    *)
        usage_and_exit
        ;;
    esac
done

shift $((OPTIND - 1))

# Validate operation argument
option="${1:-}"
case "$option" in
on | off | status | update) ;;
*)
    usage_and_exit
    ;;
esac

[ -f "$config_file" ] || {
    error_exit "Config file '$config_file' not found."
}

# shellcheck source=/dev/null
. "$config_file"

[ -n "$dns_blackhole_dir" ] || missing_config "dns_blackhole_dir"
[ -n "$named_includes_dir" ] || missing_config "named_includes_dir"
[ -n "$named_zone_files_dir" ] || missing_config "named_zone_files_dir"
[ -n "$tmp_dir" ] || missing_config "tmp_dir"
[ -n "$dns_server_hostname" ] || missing_config "dns_server_hostname"
[ -n "$fetch_timeout" ] || missing_config "fetch_timeout"
[ -n "$retry_seconds" ] || missing_config "retry_seconds"
[ -n "$max_attempts" ] || missing_config "max_attempts"
[ -n "$master_host_list_url" ] || missing_config "master_host_list_url"

for d in "$dns_blackhole_dir" "$named_includes_dir" "$named_zone_files_dir"; do
    [ -d "$d" ] || error_exit "Directory '$d' missing."
done

case "$option" in
status)
    show_status
    command_named "status"
    exit 0
    ;;
update)
    do_update
    ;;
on | off)
    switch_blackhole "$option"
    update_serial
    ;;
esac

if [ $quiet -eq 1 ]; then
    $refresh >/dev/null
else
    $refresh
fi
