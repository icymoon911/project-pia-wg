#!/bin/bash

source "$(dirname "$(realpath "$(which "$0")")")/pia-common.sh"

SERVER_VIP="$(jq -r .server_vip "$REMOTEINFO")"

ping -I$PIA_INTERFACE -n -w5 -W0.5 -c5 "$SERVER_VIP"
