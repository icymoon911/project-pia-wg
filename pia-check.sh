#!/bin/bash

LOG_PREFIX="pia-check"
PIA_COMMON="$(dirname "$(realpath "$(which "$0")")")/pia-common.sh"
[ -r "$PIA_COMMON" ] && source "$PIA_COMMON" || exit 1

SERVER_VIP="$(jq -r .server_vip "$REMOTEINFO")"

ping -I$PIA_INTERFACE -n -w5 -W0.5 -c5 "$SERVER_VIP"
