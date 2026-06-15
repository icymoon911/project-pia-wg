#!/bin/bash

# Provide logging and terminal helpers if not already defined by pia-common.sh
# This allows pia-config.sh to be sourced standalone for backward compatibility
if ! declare -f log_info >/dev/null; then
	if [ -t 2 ]; then
		BOLD=$'\e[1m'; NORMAL=$'\e[0m'
		RED=$'\e[31m'; YELLOW=$'\e[33m'; GREEN=$'\e[32m'
	else
		BOLD=""; NORMAL=""; RED=""; YELLOW=""; GREEN=""
	fi
	TAB=$'\t'
	log_info()  { echo "${BOLD}[INFO]${NORMAL} $*" >&2; }
	log_warn()  { echo "${YELLOW}[WARN]${NORMAL} $*" >&2; }
	log_error() { echo "${RED}[ERROR]${NORMAL} $*" >&2; }
fi

if [ -z "$CONFIGDIR" ]
then
	if [ $EUID -eq 0 ]
	then
		CONFIGDIR="/var/cache/pia-wg"
	else
		CONFIGDIR="$HOME/.config/pia-wg"
	fi
	mkdir -p "$CONFIGDIR"
fi

if [ -z "$CONFIG" ]
then
	if [ $EUID -eq 0 ]
	then
		CONFIG="/etc/pia-wg/pia-wg.conf"
	else
		CONFIG="$CONFIGDIR/pia-wg.conf"
	fi
fi

if [ -r "$CONFIG" ]
then
	source "$CONFIG"
fi

if [ -z "$CLIENT_PRIVATE_KEY" ]
then
	log_info "Generating new private key"
	CLIENT_PRIVATE_KEY="$(wg genkey)"
fi

if [ -z "$CLIENT_PUBLIC_KEY" ]
then
	CLIENT_PUBLIC_KEY=$(wg pubkey <<< "$CLIENT_PRIVATE_KEY")
fi

if [ -z "$CLIENT_PUBLIC_KEY" ]
then
	log_error "Failed to generate client public key, check your config!"
	exit 1
fi

if [ -z "$LOC" ]
then
	log_info "Setting default location: ${BOLD}any${NORMAL}"
	LOC="."
fi

if [ -z "$PIA_INTERFACE" ]
then
	log_info "Setting default wireguard interface name: ${BOLD}pia${NORMAL}"
	PIA_INTERFACE="pia"
fi

if [ -z "$WGCONF" ]
then
	WGCONF="$CONFIGDIR/${PIA_INTERFACE}.conf"
fi

if [ -z "$PIA_CERT" ]
then
	PIA_CERT="$CONFIGDIR/rsa_4096.crt"
fi

if [ -z "$TOKENFILE" ]
then
	TOKENFILE="$CONFIGDIR/token"
fi

if [ -z "$TOK" ] && [ -r "$TOKENFILE" ]
then
	TOK=$(< "$TOKENFILE")
fi

if [ -z "$DATAFILE" ]
then
	DATAFILE="$CONFIGDIR/data.json"
fi

if [ -z "$DATAFILE_NEW" ]
then
	DATAFILE_NEW="$CONFIGDIR/data_new.json"
fi

if [ -z "$REMOTEINFO" ]
then
	REMOTEINFO="$CONFIGDIR/remote.info"
fi

if [ -z "$CONNCACHE" ]
then
	CONNCACHE="$CONFIGDIR/cache.json"
fi

if [ -z "$HARDWARE_ROUTE_TABLE" ]
then
	# 0xca6c
	HARDWARE_ROUTE_TABLE=51820
fi

if [ -z "$VPNONLY_ROUTE_TABLE" ]
then
	# 0xca6d
	VPNONLY_ROUTE_TABLE=51821
fi

if [ -z "$PF_SIGFILE" ]
then
	PF_SIGFILE="$CONFIGDIR/pf-sig"
fi

if [ -z "$PF_BINDFILE" ]
then
	PF_BINDFILE="$CONFIGDIR/pf-bind"
fi
