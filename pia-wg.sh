#!/bin/bash

# original script posted by tpretz at https://www.reddit.com/r/PrivateInternetAccess/comments/g08ojr/is_wireguard_available_yet/fnvs20c/
# and at https://gist.github.com/tpretz/5ea1226517d95361f063f621e45de0a6
#
# significantly modified by Triffid_Hunter
#
# Improved with suggestions from Threarah at https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fv3cgi9/
#
# After the first run to fetch various data files and an auth token, this script does not require the ability to DNS resolve privateinternetaccess.com

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
			log_error "Unrecognized option: $1"
			shift
			OPT_SHOWHELP=1
			;;
	esac
done

if [ -n "$OPT_SHOWHELP" ]
then
	echo
	echo "USAGE: $(basename "$0") [-r] [-c]"
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
	log_error "The 'curl' utility is required"
	log_error "    Most package managers should have a 'curl' package available"
	EXIT=1
fi

if ! which jq &>/dev/null
then
	log_error "The 'jq' utility is required"
	log_error "    Most package managers should have a 'jq' package available"
	EXIT=1
fi

if ! which wg &>/dev/null
then
	if [ -z "$OPT_CONFIGONLY" ]
	then
		log_error "The 'wg' utility from wireguard-tools is needed to generate keys and apply settings to this machine"
	else
		log_error "The 'wg' utility from wireguard-tools is needed to generate keys"
	fi
	log_error "    Most package managers should have a 'wireguard-tools' package available"
	EXIT2=1
fi

if [ -z "$OPT_CONFIGONLY" ]
then
	if ! which ip &>/dev/null
	then
		log_error "The 'ip' utility from iproute2 is needed to apply settings to this machine"
		log_error "    Most package managers should have a 'iproute2' package available"
		EXIT2=1
	fi

	if [ -n "$EXIT2" ]
	then
		echo >&2
		log_info "You can use the -c option if you wish to only generate a config"
	fi
	EXIT="${EXIT}${EXIT2}"
else
	if ! which qrencode &>/dev/null
	then
		log_info "The 'qrencode' utility is recommended if you want to generate a config for the WireGuard Android/iOS apps"
		log_info "    It will allow you to load the config easily by scanning a QR code printed to this terminal"
		log_info "    A config will still be generated without it, but you will have to apply it by another method"
		# this is not an error, do not set EXIT
	fi
fi

source "$(dirname "$(realpath "$(which "$0")")")/pia-common.sh"

# Track temp files for cleanup on exit/signal
pia_track_temp "$DATAFILE_NEW.temp" "$REMOTEINFO.temp"

if ! [ -r "$CONFIG" ]
then
	log_info "Cannot read '$CONFIG', generating a default one"
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
	log_info "Config saved"
fi

# fetch data-new.json if missing
if ! [ -r "$DATAFILE_NEW" ]
then
	log_info "Fetching new generation server list from PIA"
	curl --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/v6' -o "$DATAFILE_NEW.temp" || exit 1
	if [ "$(head -n1 < "$DATAFILE_NEW.temp" | jq '.regions | map_values(select(.servers.wg)) | keys' 2>/dev/null | wc -l)" -le 30 ]
	then
		log_error "Bad serverlist retrieved to $DATAFILE_NEW.temp, exiting"
		log_error "You can try again if there was a transient error"
		exit 1
	else
		head -n1 < "$DATAFILE_NEW.temp" | jq -cM '.' > "$DATAFILE_NEW" 2>/dev/null
	fi
fi

if ! [ -r "$PIA_CERT" ]
then
	log_info "Fetching PIA self-signed RSA certificate from github"
	curl --max-time 15 'https://raw.githubusercontent.com/pia-foss/desktop/master/daemon/res/ca/rsa_4096.crt' > "$PIA_CERT" || exit 1
fi

if [ -n "$OPT_RECONNECT" ]
then
	rm "$CONNCACHE" "$REMOTEINFO" 2>/dev/null
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
		log_error "Location $LOC not found!"
		log_error "Options are:"
		(
			echo "${BOLD}Location${TAB}Region${TAB}Port Forward${TAB}Geolocated${NORMAL}"
			echo "----------------${TAB}------------------${TAB}------------${TAB}----------"
			jq -r --arg bold "$BOLD" --arg normal "$NORMAL" '.regions | .[] | '${PORTFORWARD:+'select(.port_forward) |'}' [.id, .name, .port_forward, .geo] | "\($bold)\(.[0])\($normal)\t\(.[1])\t\(.[2])\t\(.[3])"' "$DATAFILE_NEW" | sort
		) | column -t -s "${TAB}"
		echo "${PORTFORWARD:+'Note: only port-forwarding regions displayed'}"
		log_error "Please edit $CONFIG and change your desired location, then try again"
		exit 1
	fi

	SERVERINFO="$(jq -r ".regions[] | select(.id == \"$LOC\")" "$DATAFILE_NEW")"

	WG_NAME="$(jq -r ".name" <<< "$SERVERINFO")"
	WG_DNS="$( jq -r ".dns"  <<< "$SERVERINFO")"

	SERVERINDEX="$(jq --arg r $RANDOM '($r|tonumber) % (.servers.wg | length)' <<< "$SERVERINFO")"
	log_info "Selecting server $(( $SERVERINDEX + 1 )) from $(jq '.servers.wg | length' <<< "$SERVERINFO") choices"

	SELECTEDSERVER="$(jq --arg i $SERVERINDEX '.servers.wg[$i|tonumber]' <<< "$SERVERINFO")"

	WG_HOST="$(jq -r ".ip" <<< "$SELECTEDSERVER")"
	WG_CN="$(  jq -r ".cn" <<< "$SELECTEDSERVER")"
	WG_PORT="$(jq -r '.groups.wg[0].ports[]' "$DATAFILE_NEW" | shuf -n1)"

	jq '. | del(.servers.wg) * { "servers": { "wg": [ { "ip": "'"$WG_HOST"'", "cn": "'"$WG_CN"'" } ] } }' <<< "$SERVERINFO" > "$CONNCACHE"

	WG_SN="$(cut -d. -f1 <<< "$WG_DNS")"
fi

if [ -z "$WG_HOST$WG_PORT" ]; then
  log_error "wg host/port not found (bad server list?), exiting"
  exit 1
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
		$SUDO sh <<< "$ROUTES_ADD"
		log_info "Table $HARDWARE_ROUTE_TABLE (hardware network links) now contains:"
		ip route show table "$HARDWARE_ROUTE_TABLE" | sed -e "s/^/${TAB}/" >&2
		echo >&2
		log_warn "*** PLEASE NOTE: if this table isn't updated by your network post-connect hooks, your connection cannot remain up if your network links change"
		echo "Managing such hooks is beyond the scope of this script" >&2
	fi
fi

if ! [ -r "$REMOTEINFO" ]
then
	if [ -z "$TOK" ]
	then
		PASS="$PIA_PASSWORD"
		if [ -z "$PIA_USERNAME" ] || [ -z "$PASS" ]
		then
			log_info "A new auth token is required."
		fi
		if [ -z "$PIA_USERNAME" ]
		then
			read -p "Please enter your privateinternetaccess.com username: " PIA_USERNAME
			[ -z "$PIA_USERNAME" ] && exit 1
		fi
		if [ -z "$PASS" ]
		then
			log_info "Your password will NOT be saved."
			read -p "Please enter your privateinternetaccess.com password for $PIA_USERNAME: " -s PASS
			[ -z "$PASS" ] && exit 1
		fi
		TOK=$(curl -X POST \
			-H "Content-Type: application/json" \
			-d "{\"username\":\"$PIA_USERNAME\",\"password\":\"$PASS\"}" \
			"https://www.privateinternetaccess.com/api/client/v2/token" | jq -r '.token')
		if [ -z "$TOK" ]
		then
			log_info "failed, trying meta server"
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
			log_info "PIA API v2 failed, trying V3"
			TOK=$(curl -s -u "$PIA_USERNAME:$PASS" \
				"https://privateinternetaccess.com/gtoken/generateToken" | jq -r '.token')
		fi

		if [ -z "$PIA_PASSWORD" ]
		then
			unset PASS
			log_info "Your password has been forgotten, please edit $CONFIG and set PIA_PASSWORD if you wish to store it permanently."
		fi

		if [ -z "$TOK" ]; then
			log_error "Failed to authenticate with privateinternetaccess"
			log_error "Check your user/pass and try again"
			exit 1
		fi

		touch "$TOKENFILE"
		chmod 600 "$TOKENFILE"
		echo "$TOK" > "$TOKENFILE"

		log_info "Functional DNS is no longer required."
		log_info "If you're setting up in a region with heavy internet restrictions, you can disable your alternate VPN or connection method now"
	fi

	log_info "Registering public key with ${BOLD}$WG_NAME $WG_HOST${NORMAL}"
	[ -z "$OPT_CONFIGONLY" ] && $SUDO ip rule add to "$WG_HOST" lookup $HARDWARE_ROUTE_TABLE pref 10 2>/dev/null

	if ! curl -v -v -v -D /dev/stderr -GsS \
		--max-time 5 \
		--data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" \
		--data-urlencode "pt=$TOK" \
		--cacert "$PIA_CERT" \
		--resolve "$WG_CN:$WG_PORT:$WG_HOST" \
		"https://$WG_CN:$WG_PORT/addKey" > "$REMOTEINFO.temp"
	then
		log_warn "Registering with $WG_CN failed, trying $WG_DNS"
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
			log_error "Failed to register key with $WG_SN ($WG_HOST)"
			if ! [ -e "/sys/class/net/$PIA_INTERFACE" ]
			then
				log_error "If you're trying to change hosts because your link has stopped working,"
				log_error "  you may need to ${BOLD}ip link del dev $PIA_INTERFACE${NORMAL} and try this script again"
			fi
			rm -f "$CONNCACHE" "$REMOTEINFO"
			exit 1
		fi
	fi

	if [ "$(jq -r .status "$REMOTEINFO.temp")" != "OK" ]
	then
		log_error "WG key registration failed - bad token?"
		jq "$REMOTEINFO.temp"
		log_info "If you see an auth error, consider deleting $TOKENFILE and getting a new token"
		exit 1
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

	echo
	echo "$WGCONF generated:"
	echo
	cat "$WGCONF"
	echo
	if which qrencode &>/dev/null
	then
		qrencode -t ansiutf8 < "$WGCONF"
	fi
	echo
	exit 0
fi

# ---- WireGuard interface setup (unified for root/non-root via $SUDO) ----
if [ -n "$SUDO" ]
then
	echo
	log_info "Not running as root/sudo - did you want to specify -c (config only) ?"
	log_info "Setup commands will now be fed through sudo"
	echo
fi

if ! ip link list "$PIA_INTERFACE" > /dev/null 2>&1
then
	log_info "Bringing up interface '$PIA_INTERFACE'"

	$SUDO ip rule add fwmark 51820 lookup "$HARDWARE_ROUTE_TABLE" pref 10 2>/dev/null
	$SUDO ip link add "$PIA_INTERFACE" type wireguard || exit 1
	$SUDO ip link set dev "$PIA_INTERFACE" up || exit 1
	$SUDO wg set "$PIA_INTERFACE" fwmark 51820 private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0" || exit 1
	$SUDO ip addr replace "$PEER_IP" dev "$PIA_INTERFACE" || exit 1
else
	log_info "Updating existing interface '$PIA_INTERFACE'"

	OLD_PEER_IP="$(ip -j addr show dev "$PIA_INTERFACE" | jq -r '.[].addr_info[].local')"
	OLD_KEY="$(wg showconf "$PIA_INTERFACE" | grep ^PublicKey | cut -d= -f2- | xargs)"
	OLD_ENDPOINT="$(wg show "$PIA_INTERFACE" endpoints | grep "$OLD_KEY" | cut "-d${TAB}" -f2 | cut -d: -f1)"

	# ensure we don't get a packet storm loop
	$SUDO ip rule add fwmark 51820 lookup "$HARDWARE_ROUTE_TABLE" pref 10 2>/dev/null

	if [ "$OLD_KEY" != "$SERVER_PUBLIC_KEY" ]
	then
		log_info "Change peer from $OLD_KEY to $SERVER_PUBLIC_KEY"
		$SUDO wg set "$PIA_INTERFACE" fwmark 51820 private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0" || exit 1
		$SUDO wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove
	fi

	if [ "$PEER_IP" != "$OLD_PEER_IP/32" ]
	then
		log_info "Change $PIA_INTERFACE ipaddr from $OLD_PEER_IP to $PEER_IP"
		$SUDO ip addr replace "$PEER_IP" dev "$PIA_INTERFACE"
		$SUDO ip addr del "$OLD_PEER_IP/32" dev "$PIA_INTERFACE"
		$SUDO ip rule del to "$OLD_PEER_IP" lookup "$HARDWARE_ROUTE_TABLE" 2>/dev/null
	fi
fi

$SUDO ip route add default dev "$PIA_INTERFACE" 2>/dev/null
$SUDO ip route add default table "$VPNONLY_ROUTE_TABLE" dev "$PIA_INTERFACE" 2>/dev/null

log_info "PIA Wireguard '$PIA_INTERFACE' configured successfully"

if [ -n "$OPT_FAST" ]
then
	log_info "-f FAST supplied, skipping connection test and serverlist update"
	exit 0
fi

TRIES=0
echo -n "Waiting for connection to stabilise..." >&2
ping -n -c1 -w 1 -s 1280 -I "$PIA_INTERFACE" "$SERVER_VIP" &>/dev/null
while [ $(( $(date +%s) - $(wg show "$PIA_INTERFACE" latest-handshakes | cut $'-d\t' -f2) )) -gt 120 ]
do
	echo -n "$(wg show "$PIA_INTERFACE" latest-handshakes | cut $'-d\t' -f2)." >&2
	TRIES=$(( $TRIES + 1 ))
	if [[ $TRIES -ge 5 ]]
	then
		log_error "Connection failed to stabilise, try again"
		rm -f "$CONNCACHE" "$REMOTEINFO"
		exit 1
	fi
	sleep 1 # so we can catch ctrl+c
done
echo " OK" >&2

if find "$DATAFILE_NEW" -mtime -3 -exec false {} +
then
	log_info "PIA endpoint list is stale, fetching new generation wireguard server list"

	log_info "Trying via VPN tunnel ($WG_CN)..."
	curl --max-time 15 --interface "$PIA_INTERFACE" --cacert "$PIA_CERT" --resolve "$WG_CN:443:10.0.0.1" "https://$WG_CN:443/vpninfo/servers/v6" > "$DATAFILE_NEW.temp" || \
	curl --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/v6' > "$DATAFILE_NEW.temp" || {
		log_warn "Failed to refresh server list, using cached data"
	}

	if [ -r "$DATAFILE_NEW.temp" ]
	then
		if [ "$(jq '.regions | map_values(select(.servers.wg)) | keys' "$DATAFILE_NEW.temp" 2>/dev/null | wc -l)" -le 30 ]
		then
			log_warn "Bad serverlist in $DATAFILE_NEW.temp, keeping existing list"
		else
			jq -cM '.' "$DATAFILE_NEW.temp" > "$DATAFILE_NEW" 2>/dev/null
		fi
		rm -f "$DATAFILE_NEW.temp"
	fi
fi

if [ -n "$PORTFORWARD" ]
then
	log_info "Requesting forwarded port..."
	PIA_PORTFORWARD=""
	if which pia-portforward.sh &>/dev/null
	then
		PIA_PORTFORWARD="pia-portforward.sh"
	elif [ -e "$PIA_SCRIPT_DIR/pia-portforward.sh" ]
	then
		PIA_PORTFORWARD="$PIA_SCRIPT_DIR/pia-portforward.sh"
	fi

	if [ -n "$PIA_PORTFORWARD" ]
	then
		"$PIA_PORTFORWARD"
	else
		log_error "pia-portforward.sh couldn't be found!"
		exit 1
	fi
	log_info "Note: pia-portforward.sh should be called every ~5 minutes to maintain your forward."
	log_info "You could try:"
	echo "    while sleep 5m; do pia-portforward.sh; done" >&2
	log_info "or alternately add a cronjob with crontab -e"
fi

exit 0
