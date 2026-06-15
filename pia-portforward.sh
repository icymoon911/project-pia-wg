#!/bin/bash

source "$(dirname "$(realpath "$(which "$0")")")/pia-common.sh"

SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"

WG_INFO="$(pia_lookup_server "$SERVER_IP")" || exit 1

if [ "$(jq -r .port_forward <<< "$WG_INFO")" != true ]
then
	log_error "Current server doesn't support port forwarding:"
	jq . <<< "$WG_INFO"
	exit 1
fi

WG_NAME="$(jq -r .name <<< "$WG_INFO")"
WG_DNS="$(jq -r .dns <<< "$WG_INFO")"

WG_HOST="$(jq -r '.servers.wg[0].ip' <<< "$WG_INFO")"
WG_CN="$(jq -r '.servers.wg[0].cn' <<< "$WG_INFO")"

# sections of the below adapted from Threarah's work at
# https://github.com/thrnz/docker-wireguard-pia/blob/003f79f3b6ba24387e10d7de63ec62e98e6518a5/run#L233-L270 with permission
# Also see https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fxkpjt/

if [ -r "$PF_SIGFILE" ]
then
	PF_SIG="$(< "$PF_SIGFILE")"

	PF_PAYLOAD_RAW=$(jq -r .payload <<< "$PF_SIG")
	PF_PAYLOAD=$(base64 -d <<< "$PF_PAYLOAD_RAW")
	PF_TOKEN_EXPIRY_RAW=$(jq -r .expires_at <<< "$PF_PAYLOAD")
	PF_TOKEN_EXPIRY=$(date --date="$PF_TOKEN_EXPIRY_RAW" +%s)
fi

if [ $(( "$PF_TOKEN_EXPIRY" - $(date -u +%s) )) -le 900 ]
then
	log_info "Signature stale, refetching"

	# Very strange - must connect via 10.0/8 private VPN link to the server's public IP - why?
	# I tried SERVER_VIP (10.0/8 private IP) instead of SERVER_IP (public IP) but it won't connect
	# It also won't connect if you try to connect from the internet, hence needing --interface "$PIA_INTERFACE"
	PF_SIG="$(curl --interface "$PIA_INTERFACE" --cacert "$PIA_CERT" --get --silent --show-error --retry 5 --retry-delay 1 --max-time 2 --data-urlencode token@/dev/fd/3 --resolve "$WG_CN:19999:$SERVER_IP" "https://$WG_CN:19999/getSignature" 3< <(echo -n "$TOK") | tee "$PF_SIGFILE")"

	PF_STATUS="$(jq -r .status <<< "$PF_SIG")"
	if [ "$PF_STATUS" != "OK" ]
	then
		log_error "Signature retrieval failed: $PF_STATUS"
		jq . <<< "$PF_SIG"
		exit 1
	fi

	PF_PAYLOAD_RAW=$(jq -r .payload <<< "$PF_SIG")
	PF_PAYLOAD=$(base64 -d <<< "$PF_PAYLOAD_RAW")
	PF_TOKEN_EXPIRY_RAW=$(jq -r .expires_at <<< "$PF_PAYLOAD")
	PF_TOKEN_EXPIRY=$(date +%Y-%m-%dT%H:%M:%S --date="$PF_TOKEN_EXPIRY_RAW")
fi

PF_GETSIGNATURE=$(jq -r .signature <<< "$PF_SIG")
PF_PORT=$(jq -r .port <<< "$PF_PAYLOAD")

PF_BIND="$(curl --interface "$PIA_INTERFACE" --cacert "$PIA_CERT" --get --silent --show-error --retry 5 --retry-delay 1 --max-time 2 --data-urlencode payload@/dev/fd/3 --data-urlencode signature@/dev/fd/4 --resolve "$WG_CN:19999:$SERVER_IP" "https://$WG_CN:19999/bindPort" 3< <(echo -n "$PF_PAYLOAD_RAW") 4< <(echo -n "$PF_GETSIGNATURE") )"

PF_STATUS="$(jq -r .status <<< "$PF_BIND")"
if [ "$PF_STATUS" != "OK" ]
then
	log_error "Bind failed: $PF_STATUS"
	jq . <<< "$PF_BIND"
	exit 1
fi

log_info "PIA Server->Bind: $(jq -r .message <<< "$PF_BIND")"

echo >&2
echo -n "Bound port: " >&2
echo "$PF_PORT"
echo >&2

###############################################################################
#                                                                             #
# TODO: make this more flexible for others' systems                           #
#                                                                             #
###############################################################################

if [ "$(type -t portforward_hook)" == "function" ]
then
	log_info "Executing portforward hook ..."
	( portforward_hook $PF_PORT; )
else
	log_info "You could provide a portforward hook in your pia-wg.conf to automatically feed the bound port to some other program or system"
	log_info "To do so, add:"
	echo "    portforward_hook() { my_program $PF_PORT; }" >&2
	log_info "or similar to $CONFIG"
fi

###############################################################################
#                                                                             #
#                                                                             #
#                                                                             #
###############################################################################

exit 0
