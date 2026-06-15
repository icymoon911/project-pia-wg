#!/bin/bash

source "$(dirname "$(realpath "$(which "$0")")")/pia-common.sh"

SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"

pia_lookup_server "$SERVER_IP" || exit 1
