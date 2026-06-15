#!/bin/bash
# pia-common.sh - shared helpers for all pia-wg scripts
# Source this file from every executable script instead of duplicating
# pia-config.sh location logic, logging, cleanup and signal handling.

# ---- Locate and load pia-config.sh ----
PIA_CONFIG="$(dirname "$(realpath "$(which "$0")")")/pia-config.sh"

if ! [ -r "$PIA_CONFIG" ]
then
	echo "Can't find pia-config.sh at $PIA_CONFIG" >&2
	echo "If you've symlinked this script, please also symlink pia-config.sh" >&2
	return 1 2>/dev/null || exit 1
fi

source "$PIA_CONFIG"

# ---- Logging (all output to stderr) ----
# Color codes are set only when stderr is a terminal, so piped output
# never contains ANSI escape sequences.

if [ -t 2 ]
then
	_LOG_BOLD=$'\e[1m'
	_LOG_RED=$'\e[31m'
	_LOG_YELLOW=$'\e[33m'
	_LOG_RESET=$'\e[0m'
fi

# log "message"  -- informational message to stderr
log() {
	echo "${_LOG_BOLD}${LOG_PREFIX:+"$LOG_PREFIX: "}${_LOG_RESET}$*" >&2
}

# warn "message"  -- warning (yellow, stderr)
warn() {
	echo "${_LOG_YELLOW}${LOG_PREFIX:+"$LOG_PREFIX: "}WARNING: $*${_LOG_RESET}" >&2
}

# die "message" [exitcode]  -- fatal error (red, stderr) then exit
die() {
	echo "${_LOG_RED}${LOG_PREFIX:+"$LOG_PREFIX: "}FATAL: $1${_LOG_RESET}" >&2
	exit "${2:-1}"
}

# ---- Temporary-file cleanup and signal handling ----
# All .temp files live in $CONFIGDIR and are removed on any exit
# (normal, Ctrl+C, SIGTERM, SIGHUP).

_pia_cleanup() {
	local _files
	_files=$(find "${CONFIGDIR:-.}" -maxdepth 1 -name '*.temp' 2>/dev/null)
	if [ -n "$_files" ]; then
		echo "${LOG_PREFIX:+"$LOG_PREFIX: "}Cleaning up temporary files..." >&2
		rm -f ${_files}
	fi
}

trap _pia_cleanup EXIT
trap 'echo "${LOG_PREFIX:+"$LOG_PREFIX: "}Interrupted." >&2; exit 130' INT
trap 'echo "${LOG_PREFIX:+"$LOG_PREFIX: "}Terminated." >&2; exit 143' TERM
trap 'echo "${LOG_PREFIX:+"$LOG_PREFIX: "}Hangup received." >&2; exit 129' HUP
