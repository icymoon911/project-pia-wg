#!/bin/bash

LOG_PREFIX="pia-currentserver"
PIA_COMMON="$(dirname "$(realpath "$(which "$0")")")/pia-common.sh"
[ -r "$PIA_COMMON" ] && source "$PIA_COMMON" || exit 1

SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"

if [ -r "$CONNCACHE" ]
then
	jq . "$CONNCACHE"
else
	WG_INFO="$(pia_findserver "$SERVER_IP")" || die "Couldn't determine server information for $SERVER_IP, is your $DATAFILE_NEW ok?"
	jq . <<< "$WG_INFO"
fi
