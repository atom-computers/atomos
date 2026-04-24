#!/bin/sh
# This dispatcher script exists to configure a dnsmasq instance managed by
# NetworkManager to restrict DNS responses based on the IP configuration
# supported by NetworkManager's "Primary Connection". The script requires that
# NetworkManager is configured to use/manage dnsmasq.
# For more information about *why* this is necessary, see:
#  - https://gitlab.postmarketos.org/postmarketOS/pmaports/-/issues/1430
#  - https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/3823
# Related:
#  - https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/issues/1279

set -eu

log_tag="nm-dns-filter"
dbus="busctl --json=short"
# gojq is like... 10x faster than jq on a modest phone... (0.07s vs 0.89s)
jq=gojq

action="${2:-}"

# Get the gateway for the given connection and IP protocol version
# $1: D-Bus path to connection
# $2: IP version, e.g. '4' or '6'
get_gateway() {
	_conn="$1"
	_ver="$2"

	_ipcfg="$($dbus get-property \
		org.freedesktop.NetworkManager \
		"$_conn" \
		org.freedesktop.NetworkManager.Connection.Active \
		"Ip${_ver}Config" | $jq -r '.data')"

	if [ -z "$_ipcfg" ]; then
		logger -i -t "$log_tag" "error: unable to determine IP config for primary connection!"
		exit 1
	fi
	logger -i -t "$log_tag" "pri conn ip$_ver config path: $_ipcfg"

	_attempt=0
	# NetworkManager dispatches to the script as soon as the interface comes
	# up, which for an IPv6 network may be before the device has received an
	# Router Advertisement (RA). This means that there may be no IPv6 gateway
	# defined right now, but if we wait a few seconds an RA might arrive and a
	# gateway might become defined. NM does not dispatch to scripts when an RA
	# arrives and triggers a change in IP address / gateway / routes, so the
	# current invocation is our only chance. So we wait up to 5 seconds for the
	# gateway to be defined before deciding that the network doesn't have IPv6
	# connectivity. NetworkManager-dispatcher man page says that the dispatcher
	# will kill scripts that run for "too long", that's currently (in NM 1.42)
	# set to 10 minutes, but let's keep our timeout much shorter.
	while [ "$_attempt" -lt 5 ]; do
		_gateway="$($dbus get-property \
			org.freedesktop.NetworkManager \
			"$_ipcfg" \
			"org.freedesktop.NetworkManager.IP${_ver}Config" \
			Gateway | $jq -r '.data')"
		if [ -n "$_gateway" ]; then
			break
		fi
		sleep 1
		_attempt="$(( _attempt + 1 ))"
	done

	logger -i -t "$log_tag" "ip$_ver gateway: $_gateway"

	echo "$_gateway"
}

# $1: filter record type, e.g. 'A' or 'AAAA'
# $2: bool value, e.g. 'true' or 'false'
set_filter() {
	_type="$1"
	_val="$2"
	logger -i -t "$log_tag" "setting $_type filter to '$_val'"
	$dbus call org.freedesktop.NetworkManager.dnsmasq \
		/uk/org/thekelleys/dnsmasq \
		org.freedesktop.NetworkManager.dnsmasq \
		"SetFilter$_type" b "$_val"
}

# The up/down actions are probably(?) sufficient to act on. The goal is to only
# update filtering in dnsmasq when there's some possibility that the _primary
# connection_ has changed.
case "$action" in
	"up" | "down" | "reapply")
		;;
	*)
		# unsupported action
		exit 0
esac

primaryConn="$($dbus get-property \
	org.freedesktop.NetworkManager \
	/org/freedesktop/NetworkManager \
	org.freedesktop.NetworkManager \
	PrimaryConnection | $jq -r '.data')"

if [ -z "$primaryConn" ]; then
	logger -i -t "$log_tag" "unable to determine primary connection!"
	exit 1
fi

# This looks at the primary connection's 'gateway' property for the IP6Config
# and IP4Config interfaces, and assumes that if the gateway is unset then the
# connection does not "support" the protocol.

ip4gateway="$(get_gateway "$primaryConn" 4)"
ip6gateway="$(get_gateway "$primaryConn" 6)"

# if no gateways, disable all filtering (default dnsmasq behavior)
if [ -z "$ip4gateway" ] && [ -z "$ip6gateway" ]; then
	logger -i -t "$log_tag" "no gateways for primary connection"
	logger -i -t "$log_tag" "disabling IPv4 filter"
	set_filter A false
	logger -i -t "$log_tag" "disabling IPv6 filter"
	set_filter AAAA false
else # toggle filters individually depending on gateway status
	if [ -z "$ip4gateway" ]; then
		logger -i -t "$log_tag" "enabling IPv4 filter"
		set_filter A true
	else
		logger -i -t "$log_tag" "disabling IPv4 filter"
		set_filter A false
	fi

	if [ -z "$ip6gateway" ]; then
		logger -i -t "$log_tag" "enabling IPv6 filter"
		set_filter AAAA true
	else
		logger -i -t "$log_tag" "disabling IPv6 filter"
		set_filter AAAA false
	fi
fi

# dnsmasq will continue to use possibly unfiltered results from its cache, so
# clear the cache
# also see: https://www.mail-archive.com/dnsmasq-discuss@lists.thekelleys.org.uk/msg16695.html

$dbus call \
	org.freedesktop.NetworkManager.dnsmasq \
	/uk/org/thekelleys/dnsmasq org.freedesktop.NetworkManager.dnsmasq \
	ClearCache

logger -i -t "$log_tag" "dns filter config applied successfully"
