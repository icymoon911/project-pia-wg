#!/bin/bash

# original script posted by tpretz at https://www.reddit.com/r/PrivateInternetAccess/comments/g08ojr/is_wireguard_available_yet/fnvs20c/
# and at https://gist.github.com/tpretz/5ea1226517d95361f063f621e45de0a6
#
# significantly modified by Triffid_Hunter
#
# Improved with suggestions from Threarah at https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fv3cgi9/
#
# After the first run to fetch various data files and an auth token, this script does not require the ability to DNS resolve privateinternetaccess.com

LOG_PREFIX="pia-wg"

while [ -n "$1" ]
do
	case "$1" in
		"-r")
			shift
			OPT_RECONNECT=1
			;;
		"-c")
			shift
			OPT_CONFIGONLY=1
			;;
		"-h")
			shift
			OPT_SHOWHELP=1
			;;
		"-f")
			shift
			OPT_FAST=1
			;;
		*)
			echo "Unrecognized option: $1" >&2
			shift
			OPT_SHOWHELP=1
			;;
	esac
done

if [ -n "$OPT_SHOWHELP" ]
then
	echo
	echo "USAGE: $(basename "$0") [-r] [-c] [-f]"
	echo
	echo "    -r  Force reconnection or server hop even if a cached link is available"
	echo
	echo "    -c  Config only - generate a WireGuard config but do not apply it to this system"
	echo "        Use this option for creating Android/iOS/router Wireguard configurations"
	echo
	echo "    -f  Fast reconnect if cached link is present - don't test connection or fetch updated serverlist"
	echo "        Does nothing if cached link information is absent, or if -r is specified"
	echo
	exit 1
fi

if ! which curl &>/dev/null
then
	echo "The 'curl' utility is required" >&2
	echo "    Most package managers should have a 'curl' package available" >&2
	EXIT=1
fi

if ! which jq &>/dev/null
then
	echo "The 'jq' utility is required" >&2
	echo "    Most package managers should have a 'jq' package available" >&2
	EXIT=1
fi

if ! which wg &>/dev/null
then
	echo -n "The 'wg' utility from wireguard-tools is needed to generate keys" >&2
	[ -z "$OPT_CONFIGONLY" ] && echo -n " and apply settings to this machine" >&2
	echo >&2
	echo "    Most package managers should have a 'wireguard-tools' package available" >&2
	EXIT2=1
fi

if [ -z "$OPT_CONFIGONLY" ]
then
	if ! which ip &>/dev/null
	then
		echo "The 'ip' utility from iproute2 is needed to apply settings to this machine" >&2
		echo "    Most package managers should have a 'iproute2' package available" >&2
		EXIT2=1
	fi

	if [ -n "$EXIT2" ]
	then
		echo >&2
		echo "You can use the -c option if you wish to only generate a config" >&2
	fi
	EXIT="${EXIT}${EXIT2}"
else
	if ! which qrencode &>/dev/null
	then
		echo "The 'qrencode' utility is recommended if you want to generate a config for the WireGuard Android/iOS apps" >&2
		echo "    It will allow you to load the config easily by scanning a QR code printed to this terminal" >&2
		echo "    A config will still be generated without it, but you will have to apply it by another method" >&2
		# this is not an error, do not set EXIT
	fi
fi

# Load common helpers (locates and sources pia-config.sh, sets up logging, cleanup, signal traps)
PIA_COMMON="$(dirname "$(realpath "$(which "$0")")")/pia-common.sh"
if ! [ -r "$PIA_COMMON" ]
then
	echo "Can't find pia-common.sh at $PIA_COMMON" >&2
	EXIT=1
fi

[ -n "$EXIT" ] && exit 1

source "$PIA_COMMON"

if ! [ -r "$CONFIG" ]
then
	log "Cannot read '$CONFIG', generating a default one"
	if [ -z "$PIA_USERNAME" ]
	then
		read -p "Please enter your privateinternetaccess.com username: " PIA_USERNAME
	fi
	mkdir -p "$(dirname "$CONFIG")"
	cat <<ENDCONFIG > "$CONFIG"
# your privateinternetaccess.com username (not needed if you already have an auth token)
PIA_USERNAME="$PIA_USERNAME"

# [OPTIONAL] your privateinternetaccess.com password (only needed once for v2 tokens, will be requested when needed if absent here)
# PIA_PASSWORD=""

# your desired endpoint location
LOC="$LOC"

# the name of the network interface (default: pia)
# PIA_INTERFACE="$PIA_INTERFACE"

# wireguard client-side private key (new key generated every invocation if not specified)
CLIENT_PRIVATE_KEY="$CLIENT_PRIVATE_KEY"

# if PORTFORWARD is set, pia-wg will only connect to port-forward capable servers, and will invoke pia-portforward.sh after connection
# PORTFORWARD="literally anything"

# If you have an existing routing table that only contains routes for hardware interfaces, specify it here
# this will allow pia-wg to hop endpoints without requiring you to disconnect first
# HARDWARE_ROUTE_TABLE="hardlinks"

# If you have daemons that you want to force to only use the VPN and already have a routing table for this purpose, specify it here
# pia-wg will add a default route via the PIA VPN link to that table for you
# VPNONLY_ROUTE_TABLE="vpnonly"

# post-portforward hook
# you can use \$PF_PORT for the received port numberr
# PORTFORWARD_HOOK="my_program \$PF_PORT"
ENDCONFIG
	log "Config saved"
fi

# fetch data-new.json if missing
if ! [ -r "$DATAFILE_NEW" ]
then
	log "Fetching new generation server list from PIA"
	curl --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/v6' -o "$DATAFILE_NEW.temp" || die "Failed to download server list"
	if [ "$(head -n1 < "$DATAFILE_NEW.temp" | jq '.regions | map_values(select(.servers.wg)) | keys' 2>/dev/null | wc -l)" -le 30 ]
	then
		die "Bad serverlist retrieved to $DATAFILE_NEW.temp; you can try again if there was a transient error"
	else
		head -n1 < "$DATAFILE_NEW.temp" | jq -cM '.' > "$DATAFILE_NEW" 2>/dev/null
	fi
fi

if ! [ -r "$PIA_CERT" ]
then
	log "Fetching PIA self-signed RSA certificate from github"
	curl --max-time 15 'https://raw.githubusercontent.com/pia-foss/desktop/master/daemon/res/ca/rsa_4096.crt' > "$PIA_CERT" || die "Failed to download PIA certificate"
fi

if [ -n "$OPT_RECONNECT" ]
then
	rm -f "$CONNCACHE" "$REMOTEINFO" 2>/dev/null
fi

if [ -r "$CONNCACHE" ]
then
	WG_NAME="$(jq -r ".name" "$CONNCACHE")"
	WG_DNS="$(jq -r ".dns"  "$CONNCACHE")"

	WG_HOST="$(jq -r ".servers.wg[0].ip"     "$CONNCACHE")"
	WG_CN="$(jq -r ".servers.wg[0].cn"     "$CONNCACHE")"
	WG_PORT="$(jq -r '.groups.wg[0].ports[]' "$DATAFILE_NEW" | sort -r | head -n1)"

	WG_SN="$(cut -d. -f1 <<< "$WG_DNS")"
fi

if [ -z "$WG_HOST" ] || [ -z "$WG_CN" ] || [ -z "$WG_PORT" ]
then
	if [ "$(jq -r ".regions | .[] | select(.id == \"$LOC\")" "$DATAFILE_NEW")" == "" ]
	then
		LOC=$(jq -r '.regions | .[] | select(.id | test("^'"$LOC"'")) '${PORTFORWARD:+'| select(.port_forward) '}'| .id' "$DATAFILE_NEW" | shuf -n 1)
	fi

	if [ "$(jq -r ".regions | .[] | select(.id == \"$LOC\")" "$DATAFILE_NEW")" == "" ]
	then
		echo "Location $LOC not found!" >&2
		echo "Options are:" >&2
	# 	jq '.regions | .[] | .id' "$DATAFILE_NEW" | sort | sed -e 's/^/ * /'
		(
			echo "${BOLD}Location${TAB}Region${TAB}Port Forward${TAB}Geolocated${NORMAL}"
			echo "----------------${TAB}------------------${TAB}------------${TAB}----------"
			jq -r '.regions | .[] | '${PORTFORWARD:+'select(.port_forward) |'}' [.id, .name, .port_forward, .geo] | "'$'\e''[1m\(.[0])'$'\e''[0m\t\(.[1])\t\(.[2])\t\(.[3])"' "$DATAFILE_NEW" | sort
		) | column -t -s "${TAB}" >&2
		echo "${PORTFORWARD:+'Note: only port-forwarding regions displayed'}" >&2
		die "Please edit $CONFIG and change your desired location, then try again"
	fi

	SERVERINFO="$(jq -r ".regions[] | select(.id == \"$LOC\")" "$DATAFILE_NEW")"

	WG_NAME="$(jq -r ".name" <<< "$SERVERINFO")"
	WG_DNS="$( jq -r ".dns"  <<< "$SERVERINFO")"

	SERVERINDEX="$(jq --arg r $RANDOM '($r|tonumber) % (.servers.wg | length)' <<< "$SERVERINFO")"
	log "Selecting server $(( $SERVERINDEX + 1 )) from $(jq '.servers.wg | length' <<< "$SERVERINFO") choices"

	SELECTEDServer="$(jq --arg i $SERVERINDEX '.servers.wg[$i|tonumber]' <<< "$SERVERINFO")"

	WG_HOST="$(jq -r ".ip" <<< "$SELECTEDSERVER")"
	WG_CN="$(  jq -r ".cn" <<< "$SELECTEDSERVER")"
	WG_PORT="$(jq -r '.groups.wg[0].ports[]' "$DATAFILE_NEW" | shuf -n1)"

	jq '. | del(.servers.wg) * { "servers": { "wg": [ { "ip": "'"$WG_HOST"'", "cn": "'"$WG_CN"'" } ] } }' <<< "$SERVERINFO" > "$CONNCACHE"

	WG_SN="$(cut -d. -f1 <<< "$WG_DNS")"
fi

if [ -z "$WG_HOST$WG_PORT" ]; then
  die "wg host/port not found (bad server list?)"
fi

if [ -z "$OPT_CONFIGONLY" ]
then
	if ! ip route show table "$HARDWARE_ROUTE_TABLE" 2>/dev/null | grep -q .
	then
		ROUTES_ADD=$(
			for IF in $(ip link show | grep -B1 'link/ether' | grep '^[0-9]' | cut -d: -f2)
			do
				ip route show | grep "dev $IF" | sed -e 's/linkdown//' | sed -e "s/^/ip route add table $HARDWARE_ROUTE_TABLE /"
			done
		)
		if [ "$EUID" -eq 0 ]
		then
			sh <<< "$ROUTES_ADD"
		else
			log "Build a routing table with only hardware links to stop wireguard packets going back through the VPN:"
			echo sudo sh '<<<' "$ROUTES_ADD" >&2
			sudo sh <<< "$ROUTES_ADD"
		fi
		log "Table $HARDWARE_ROUTE_TABLE (hardware network links) now contains:"
		ip route show table "$HARDWARE_ROUTE_TABLE" | sed -e "s/^/${TAB}/" >&2
		echo >&2
		log "${BOLD}*** PLEASE NOTE: if this table isn't updated by your network post-connect hooks, your connection cannot remain up if your network links change${NORMAL}"
		log "Managing such hooks is beyond the scope of this script"
	fi
fi

if ! [ -r "$REMOTEINFO" ]
then
	if [ -z "$TOK" ]
	then
		PASS="$PIA_PASSWORD"
		if [ -z "$PIA_USERNAME" ] || [ -z "$PASS" ]
		then
			log "A new auth token is required."
		fi
		if [ -z "$PIA_USERNAME" ]
		then
			read -p "Please enter your privateinternetaccess.com username: " PIA_USERNAME
			[ -z "$PIA_USERNAME" ] && die "No username provided"
		fi
		if [ -z "$PASS" ]
		then
			log "Your password will NOT be saved."
			read -p "Please enter your privateinternetaccess.com password for $PIA_USERNAME: " -s PASS
			[ -z "$PASS" ] && die "No password provided"
		fi
		TOK=$(curl -X POST \
			-H "Content-Type: application/json" \
			-d "{\"username\":\"$PIA_USERNAME\",\"password\":\"$PASS\"}" \
			"https://www.privateinternetaccess.com/api/client/v2/token" | jq -r '.token')
		if [ -z "$TOK" ]
		then
			log "PIA API v2 failed, trying meta server"
			METASERVER="$(jq -r ".servers.meta[0].ip" "$CONNCACHE")"
			METADNS="$(jq -r ".servers.meta[0].cn" "$CONNCACHE")"
			TOK=$(curl -s \
				--cacert "$PIA_CERT" \
				--resolve "$METADNS:443:$METASERVER" \
				-u "$PIA_USERNAME:$PASS" \
				"https://$METADNS/authv3/generateToken" \
				| jq -r ".token")
		fi
		if [ -z "$TOK" ]
		then
			log "PIA API v2 and meta failed, trying v3"
			TOK=$(curl -s -u "$PIA_USERNAME:$PASS" \
				"https://privateinternetaccess.com/gtoken/generateToken" | jq -r '.token')
		fi

		if [ -z "$PIA_PASSWORD" ]
		then
			unset PASS
			log "Your password has been forgotten, please edit $CONFIG and set PIA_PASSWORD if you wish to store it permanently."
		fi

		if [ -z "$TOK" ]; then
			die "Failed to authenticate with privateinternetaccess - check your user/pass and try again"
		fi

		touch "$TOKENFILE"
		chmod 600 "$TOKENFILE"
		echo "$TOK" > "$TOKENFILE"

		log "Functional DNS is no longer required."
		log "If you're setting up in a region with heavy internet restrictions, you can disable your alternate VPN or connection method now"
	fi

	log "Registering public key with ${BOLD}$WG_NAME $WG_HOST${NORMAL}"
	[ "$EUID" -eq 0 ] && [ -z "$OPT_CONFIGONLY" ] && ip rule add to "$WG_HOST" lookup $HARDWARE_ROUTE_TABLE pref 10 2>/dev/null

	if ! curl -v -v -v -D /dev/stderr -GsS \
		--max-time 5 \
		--data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" \
		--data-urlencode "pt=$TOK" \
		--cacert "$PIA_CERT" \
		--resolve "$WG_CN:$WG_PORT:$WG_HOST" \
		"https://$WG_CN:$WG_PORT/addKey" > "$REMOTEINFO.temp"
	then
		warn "Registering with $WG_CN failed, trying $WG_DNS"
		# fall back to trying DNS certificate if CN fails
		# /u/dean_oz reported that this works better for them at https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fyfqjf7/
		# in testing I find that sometimes one works, sometimes the other works
		if ! curl -GsS \
			--max-time 5 \
			--data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" \
			--data-urlencode "pt=$TOK" \
			--cacert "$PIA_CERT" \
			--resolve "$WG_DNS:$WG_PORT:$WG_HOST" \
			"https://$WG_DNS:$WG_PORT/addKey" > "$REMOTEINFO.temp"
		then
			warn "Failed to register key with $WG_SN ($WG_HOST)"
			if ! [ -e "/sys/class/net/$PIA_INTERFACE" ]
			then
				log "If you're trying to change hosts because your link has stopped working,"
				log "  you may need to ${BOLD}ip link del dev $PIA_INTERFACE${NORMAL} and try this script again"
			fi
			rm -f "$CONNCACHE" "$REMOTEINFO"
			die "Key registration failed"
		fi
	fi

	if [ "$(jq -r .status "$REMOTEINFO.temp")" != "OK" ]
	then
		jq "$REMOTEINFO.temp" >&2
		log "If you see an auth error, consider deleting $TOKENFILE and getting a new token"
		die "WG key registration failed - bad token?"
	fi

	mv  "$REMOTEINFO.temp" \
		"$REMOTEINFO"

	unset OPT_FAST
fi

PEER_IP="$(jq -r .peer_ip "$REMOTEINFO")"
SERVER_PUBLIC_KEY="$(jq -r .server_key  "$REMOTEINFO")"
SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"
SERVER_PORT="$(jq -r .server_port "$REMOTEINFO")"
SERVER_VIP="$(jq -r .server_vip "$REMOTEINFO")"

if [ -n "$OPT_CONFIGONLY" ]
then
	cat > "$WGCONF" <<ENDWG
	[Interface]
	PrivateKey = $CLIENT_PRIVATE_KEY
	Address    = $PEER_IP
	DNS        = $(jq -r '.dns_servers[0:2]' "$REMOTEINFO" | grep ^\  | cut -d\" -f2 | xargs echo | sed -e 's/ /,/g')

	[Peer]
	PublicKey  = $SERVER_PUBLIC_KEY
	AllowedIPs = 0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, ::/0
	Endpoint   = $SERVER_IP:$SERVER_PORT
ENDWG

	echo >&2
	log "$WGCONF generated:"
	echo >&2
	cat "$WGCONF"
	echo >&2
	if which qrencode &>/dev/null
	then
		qrencode -t ansiutf8 < "$WGCONF"
	fi
	echo >&2
	exit 0
fi

# ---- Configure WireGuard interface ----
# Use $SUDO prefix: empty when running as root, "sudo" otherwise.
# This lets us write the ip/wg commands once instead of duplicating them.
SUDO=""
if [ "$EUID" -ne 0 ]
then
	log "Not running as root/sudo - did you want to specify -c (config only)?"
	log "Setup commands will now be fed through sudo"
	echo >&2
	SUDO="sudo"
fi

if ip link list "$PIA_INTERFACE" > /dev/null 2>&1
then
	log "Updating existing interface '$PIA_INTERFACE'"

	OLD_PEER_IP="$(ip -j addr show dev "$PIA_INTERFACE" | jq -r '.[].addr_info[].local')"
	OLD_KEY="$(wg showconf "$PIA_INTERFACE" | grep ^PublicKey | cut -d= -f2-)"
	OLD_ENDPOINT="$(wg show "$PIA_INTERFACE" endpoints | grep "$OLD_KEY" | cut "-d${TAB}" -f2 | cut -d: -f1)"

	# ensure we don't get a packet storm loop
	$SUDO ip rule add fwmark 51820 lookup "$HARDWARE_ROUTE_TABLE" pref 10 2>/dev/null

	if [ "$OLD_KEY" != "$SERVER_PUBLIC_KEY" ]
	then
		log "    [Change Peer from $OLD_KEY to $SERVER_PUBLIC_KEY]"
		$SUDO wg set "$PIA_INTERFACE" fwmark 51820 private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0" \
			|| die "Failed to update WireGuard peer"
		# remove old key
		$SUDO wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove \
			|| die "Failed to remove old WireGuard peer"
	fi

	if [ "$PEER_IP" != "$OLD_PEER_IP/32" ]
	then
		log "    [Change $PIA_INTERFACE ipaddr from $OLD_PEER_IP to $PEER_IP]"
		$SUDO ip addr replace "$PEER_IP" dev "$PIA_INTERFACE" \
			|| die "Failed to set IP address"
		$SUDO ip addr del "$OLD_PEER_IP/32" dev "$PIA_INTERFACE" 2>/dev/null

		# remove old route
		$SUDO ip rule del to "$OLD_PEER_IP" lookup "$HARDWARE_ROUTE_TABLE" 2>/dev/null
	fi

	$SUDO ip link set dev "$PIA_INTERFACE" up \
		|| die "Failed to bring up interface"

	# Note: only if Table = off in wireguard config file above
	$SUDO ip route add default dev "$PIA_INTERFACE" 2>/dev/null

	# Specific to my setup
	$SUDO ip route add default table "$VPNONLY_ROUTE_TABLE" dev "$PIA_INTERFACE" 2>/dev/null
else
	log "Bringing up interface '$PIA_INTERFACE'"

	# ensure we don't get a packet storm loop
	$SUDO ip rule add fwmark 51820 lookup "$HARDWARE_ROUTE_TABLE" pref 10 2>/dev/null

	# bring up wireguard interface
	$SUDO ip link add "$PIA_INTERFACE" type wireguard \
		|| die "Failed to create WireGuard interface"
	$SUDO ip link set dev "$PIA_INTERFACE" up \
		|| die "Failed to bring up WireGuard interface"
	$SUDO wg set "$PIA_INTERFACE" fwmark 51820 private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0" \
		|| die "Failed to configure WireGuard"
	$SUDO ip addr replace "$PEER_IP" dev "$PIA_INTERFACE" \
		|| die "Failed to set IP address"

	# Note: only if Table = off in wireguard config file above
	$SUDO ip route add default dev "$PIA_INTERFACE" 2>/dev/null

	# Specific to my setup
	$SUDO ip route add default table "$VPNONLY_ROUTE_TABLE" dev "$PIA_INTERFACE" 2>/dev/null
fi

log "PIA Wireguard '$PIA_INTERFACE' configured successfully"

if [ -n "$OPT_FAST" ]
then
	log "-f FAST supplied, skipping connection test and serverlist update"
	exit 0
fi

TRIES=0
log "Waiting for connection to stabilise..."
ping -n -c1 -w 1 -s 1280 -I "$PIA_INTERFACE" "$SERVER_VIP" &>/dev/null
while [ $(( $(date +%s) - $(wg show "$PIA_INTERFACE" latest-handshakes | cut $'-d\t' -f2) )) -gt 120 ]
do
	echo -n "$(wg show "$PIA_INTERFACE" latest-handshakes | cut $'-d\t' -f2)." >&2
	TRIES=$(( $TRIES + 1 ))
	if [[ $TRIES -ge 5 ]]
	then
		rm -f "$CONNCACHE" "$REMOTEINFO"
		die "Connection failed to stabilise, try again"
	fi
	sleep 1 # so we can catch ctrl+c
done
log "Connection stable"

if find "$DATAFILE_NEW" -mtime -3 -exec false {} +
then
	log "PIA endpoint list is stale, fetching new generation wireguard server list"

	log "curl --max-time 15 --interface $PIA_INTERFACE --cacert $PIA_CERT --resolve $WG_CN:443:10.0.0.1 https://$WG_CN:443/vpninfo/servers/v6"
	if ! curl --max-time 15 --interface "$PIA_INTERFACE" --cacert "$PIA_CERT" --resolve "$WG_CN:443:10.0.0.1" "https://$WG_CN:443/vpninfo/servers/v6" > "$DATAFILE_NEW.temp"
	then
		if ! curl --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/v6' > "$DATAFILE_NEW.temp"
		then
			# Serverlist refresh failure is NOT fatal — the VPN connection is still up.
			# Warn and continue with the stale (but functional) list.
			warn "Failed to refresh server list; continuing with existing (stale) list"
			DATAFILE_NEW_FETCHED=0
		fi
	fi

	if [ "${DATAFILE_NEW_FETCHED:-1}" -eq 1 ] && [ "$(jq '.regions | map_values(select(.servers.wg)) | keys' "$DATAFILE_NEW.temp" 2>/dev/null | wc -l)" -le 30 ]
	then
		warn "Bad serverlist retrieved to $DATAFILE_NEW.temp; keeping existing list"
		rm -f "$DATAFILE_NEW.temp"
	elif [ "${DATAFILE_NEW_FETCHED:-1}" -eq 1 ]
	then
		jq -cM '.' "$DATAFILE_NEW.temp" > "$DATAFILE_NEW" 2>/dev/null
	fi
fi

if [ -n "$PORTFORWARD" ]
then
	log "Requesting forwarded port..."
	if which pia-portforward.sh &>/dev/null
	then
		pia-portforward.sh
	else
		if [ -e "${0%/*}/pia-portforward.sh" ]
		then
			"${0%/*}/pia-portforward.sh"
		else
			PIA_PORTFORWARD="$(dirname "$(realpath "$(which "$0")")")/pia-portforward.sh"
			if [ -e "$PIA_PORTFORWARD" ]
			then
				"$PIA_PORTFORWARD"
			else
				die "pia-portforward.sh couldn't be found!"
			fi
		fi
	fi
	log "Note: pia-portforward.sh should be called every ~5 minutes to maintain your forward."
	log "You could try:"
	log "    while sleep 5m; do pia-portforward.sh; done"
	log "or alternately add a cronjob with crontab -e"
fi

exit 0
