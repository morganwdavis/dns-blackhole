[![Ads being sucked into a DNS blackhole](https://www.morgandavis.net/content/uploads/2025/04/simple-dns-blackhole.webp){loading="eager" width="1024" height="1024"}](https://www.morgandavis.net/content/uploads/2025/04/simple-dns-blackhole.webp 'DNS Blackhole')

**Tired of Annoying Ads and Privacy-Invading Trackers? Here's How to Take Control**

Are you frustrated with pop-up ads in your browser or ads cluttering news articles? Not to mention those pesky privacy-invading trackers? You're not alone -- but the good news is, you don't have to put up with them.

## First Protect Your Browser

The first step is to enable privacy settings in your browsers and install an ad-blocking extension like [uBlock Origin](https://ublockorigin.com/). This will block ads in your browser, but that's just one part of the solution. You can also take things a step further by setting up a **DNS blackhole** on your local network. This will send ads and trackers to a dead-end, keeping your devices protected across your entire home network.

A DNS blackhole works by redirecting requests for known ad-serving and tracker domains to a non-existent address, effectively blocking them. There are many options available, from free DIY solutions to paid DNS subscription services.

## Add a DNS Blackhole to Your Network

If you're running your own home network with a Unix-based server, you can easily integrate a DNS blackhole into a local BIND DNS service -- and best of all, it's completely free. If you're already using BIND and know your way around it, you can use this script to manage BIND's Response Policy Zone (RPZ) feature. RPZ is designed for DNS firewall/blocking purposes. The script _should_ run on \*BSD and Linux distros with proper pathnames configured. Out of the box, it has a FreeBSD default configuration.

> The source of the blocked host list is provided by [Steven Black on GitHub](https://github.com/StevenBlack/hosts). See his page for full details.

## Steps

Refer to the sample files below for these steps.

1. Create a `/usr/local/etc/dns-blackhole` directory
2. Copy `dns-blackhole.sh` into this new directory
3. Create and configure your `dns-blackhole.conf` file here

```
Usage: ./dns-blackhole.sh <on|off|status|update> [config_file]
```

4. Run `dns-blackhole.sh` `update` and make sure there are no errors before continuing
5. Add this entry inside of the `options` block in BIND's `named.conf`:

```text
response-policy { zone "rpz"; };
```

6. Add this to the end of `named.conf`:

```text
include "/usr/local/etc/namedb/dns-blackhole.zone";
```

7. Enable the blackhole now with `dns-blackhole.sh` `on`
8. Test to make sure it's working (see [Testing](#testing) below)
9. Add an entry in crontab or periodic to automate updates

---

## Files Added in Your `namedb` Directory

-   `dns-blackhole.zone` - included zone file
-   `dns-blackhole-enabled.rpz` - list of blocked hostnames
-   `dns-blackhole-disabled.rpz` - empty list for disabled mode
-   `dns-blackhole.rpz` - symlink (set by `on` and `off`)

---

## `dns-blackhole.sh`

Copy this script to your `dns_blackhole_dir` directory.

```sh
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
```

## Sample `dns-blackhole.conf`

Create this in your `dns_blackhole_dir` directory.

```shell
#
# dns-blackhole.conf.dist
#

# Directory in which to store configs and build zone data
dns_blackhole_dir="/usr/local/etc/dns-blackhole"

# Path to your BIND namedb directory where included files go
named_includes_dir="/usr/local/etc/namedb"

# Path to your BIND namedb directory where zone data files go
named_zone_files_dir="/usr/local/etc/namedb"

# Temporary directory in which to fetch and build zone files
tmp_dir="/var/tmp/dns-blackhole"

# The fully qualified hostname of your nameserver
dns_server_hostname="localhost"

# Seconds before fetch times out
fetch_timeout="15"

# Seconds to wait between fetch retries
retry_seconds="10"

# Maximum number of fetch attempts before giving up
max_attempts="3"

# Master host list URL
master_host_list_url="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"

# Debug mode: 0=disabled, 1=enabled
debug="0"
```

## `allowed_hosts`

```
#
# allowed_hosts.dist
#
# Add hostnames, one per line, to omit from the DNS blackhole.
```

## `blocked_hosts`

```
#
# blocked_hosts.dist
#
# Add host entries, one per line, to add to the DNS blackhole.
# Format is similar to /etc/hosts with 0.0.0.0 addresses:
#
# 0.0.0.0 example.com
```

---

## Sample Output

```
# ./dns-blackhole.sh update
Fetching master host list...
Optimizing hosts list...
Excluding allowed hosts...
Installing enabled/disabled RPZ zone files...
Building included zone file...
Cleaning up...
DNS blackhole switched off.
Stopping named.
Waiting for PIDS: 65473.
Starting named.

# ./dns-blackhole.sh on
DNS blackhole switched on.
Stopping named.
Waiting for PIDS: 39147.
Starting named.

# ./dns-blackhole.sh status
DNS blackhole is on.
named is running as pid 39227.
```

## Sample Crontab Entry

```text
#
#minute hour    mday    month   wday    command
#

15      4       *       *       *       /usr/local/etc/dns-blackhole/dns-blackhole.sh update 2>&1 | mail -s "Update DNS blackhole zone" root
```

## Testing {#testing}

Simple test to see if it is working using one of the hostnames in the `dns-blackhole-enabled.rpz` file.

```text
# host 00fun.com
Host 00fun.com not found: 3(NXDOMAIN)
```

Yay! It's blocked when using the local DNS resolver.

To test the opposite function (no blackhole DNS), you can switch the blackhole off and try the lookup again. Or keep it enabled but use an external nameserver like 1.1.1.1 or 8.8.8.8:

```text
# host 00fun.com 1.1.1.1
Using domain server:
Name: 1.1.1.1
Address: 1.1.1.1#53
Aliases:

00fun.com has address 74.53.201.226
00fun.com mail is handled by 1 mx1.comspec.com.
```

This proves that it would otherwise resolve with the DNS blackhole disabled.
