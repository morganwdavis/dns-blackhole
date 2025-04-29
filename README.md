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
# @source https://raw.githubusercontent.com/morganwdavis/dns-blackhole/refs/heads/main/dns-blackhole.sh
```

## Sample `dns-blackhole.conf`

Create this in your `dns_blackhole_dir` directory.

```sh
# @source https://raw.githubusercontent.com/morganwdavis/dns-blackhole/refs/heads/main/dns-blackhole.conf.dist
```

## `allowed_hosts`

```
# @source https://raw.githubusercontent.com/morganwdavis/dns-blackhole/refs/heads/main/allowed_hosts.dist
```

## `blocked_hosts`

```
# @source https://raw.githubusercontent.com/morganwdavis/dns-blackhole/refs/heads/main/blocked_hosts.dist
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
