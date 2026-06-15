#!/bin/bash
# pia-common.sh — Common initialization, functions, and cleanup for pia-wg scripts
# Source this from other scripts instead of pia-config.sh directly.

# ---- Script directory detection ----
PIA_SCRIPT_DIR="$(dirname "$(realpath "$(which "$0")")")"
_PIA_CONFIG_PATH="$PIA_SCRIPT_DIR/pia-config.sh"

if ! [ -r "$_PIA_CONFIG_PATH" ]; then
	echo "Can't find pia-config.sh at $_PIA_CONFIG_PATH — if you've symlinked this script, please also symlink pia-config.sh" >&2
	exit 1
fi

# ---- Terminal colors (set before pia-config.sh so it can use them) ----
if [ -t 2 ]; then
	BOLD=$'\e[1m'
	NORMAL=$'\e[0m'
	RED=$'\e[31m'
	YELLOW=$'\e[33m'
	GREEN=$'\e[32m'
else
	BOLD=""
	NORMAL=""
	RED=""
	YELLOW=""
	GREEN=""
fi
TAB=$'\t'

# ---- Logging functions (all output goes to stderr) ----
log_info() {
	echo "${BOLD}[INFO]${NORMAL} $*" >&2
}

log_warn() {
	echo "${YELLOW}[WARN]${NORMAL} $*" >&2
}

log_error() {
	echo "${RED}[ERROR]${NORMAL} $*" >&2
}

# ---- Source configuration ----
source "$_PIA_CONFIG_PATH"

# ---- Privilege helper ----
if [ "$EUID" -eq 0 ]; then
	SUDO=""
else
	SUDO="sudo"
fi

# ---- Temp file tracking and cleanup ----
_PIA_TEMP_FILES=()

pia_track_temp() {
	_PIA_TEMP_FILES+=("$@")
}

pia_cleanup() {
	local f
	for f in "${_PIA_TEMP_FILES[@]}"; do
		rm -f "$f" 2>/dev/null
	done
	if declare -f pia_extra_cleanup >/dev/null; then
		pia_extra_cleanup
	fi
}

_pia_on_signal() {
	log_warn "Signal received, cleaning up..."
	pia_cleanup
	if [ -n "$PIA_INTERFACE" ] && ip link list "$PIA_INTERFACE" >/dev/null 2>&1; then
		log_warn "WireGuard interface '$PIA_INTERFACE' may still be active"
		log_warn "Remove with: ${SUDO:+sudo }ip link del dev $PIA_INTERFACE"
	fi
	exit 130
}

trap pia_cleanup EXIT
trap _pia_on_signal INT TERM

# ---- Server lookup function ----
# Looks up server info by IP: tries CONNCACHE → exact match → fuzzy match.
# Outputs pretty-printed JSON to stdout. Returns non-zero if not found.
# Usage: WG_INFO="$(pia_lookup_server "$SERVER_IP")" || exit 1
pia_lookup_server() {
	local server_ip="$1"
	local info=""

	# Try connection cache first
	if [ -r "$CONNCACHE" ]; then
		info="$(jq -c . "$CONNCACHE" 2>/dev/null)"
	fi

	# Try exact IP match in server list
	if [ -z "$info" ] && [ -r "$DATAFILE_NEW" ]; then
		info="$(jq -c '.regions | .[] | select(.servers.wg[0].ip == "'"$server_ip"'")' "$DATAFILE_NEW" 2>/dev/null)"
	fi

	# Try fuzzy match on first 3 octets
	if [ -z "$info" ] && [ -r "$DATAFILE_NEW" ]; then
		local ip_prefix
		ip_prefix="$(cut -d. -f1-3 <<< "$server_ip")"
		info="$(jq -c '.regions | .[] | select(.servers.wg[0].ip | test("^'"$ip_prefix"'"))' "$DATAFILE_NEW" 2>/dev/null)"
		if [ -n "$info" ]; then
			log_warn "Inexact match for ${ip_prefix}.* ($server_ip not found)"
		fi
	fi

	if [ -z "$info" ]; then
		log_error "Couldn't determine server information for $server_ip, is your $DATAFILE_NEW ok?"
		return 1
	fi

	jq . <<< "$info"
}
