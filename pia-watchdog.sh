#!/bin/bash
#
# pia-watchdog.sh - VPN connection watchdog for pia-wg
#
# Monitors the PIA WireGuard connection and automatically reconnects
# when a disconnection is detected.
#
# Usage: pia-watchdog.sh {start|stop|status|restart}
#
# Configuration variables (set in pia-wg.conf or environment):
#   WATCHDOG_INTERVAL   Seconds between connectivity checks    (default: 30)
#   WATCHDOG_THRESHOLD  Consecutive failures before reconnect  (default: 3)
#   WATCHDOG_MAX_RETRY  Max reconnect attempts before giving up (default: 5)
#   WATCHDOG_RETRY_DELAY Seconds between reconnect attempts    (default: 10)
#   PF_REFRESH_INTERVAL Seconds between portforward refreshes  (default: 600)
#

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PIA_CONFIG="${SCRIPT_DIR}/pia-config.sh"
PIA_WG="${SCRIPT_DIR}/pia-wg.sh"
PIA_PORTFORWARD="${SCRIPT_DIR}/pia-portforward.sh"

if ! [ -r "$PIA_CONFIG" ]; then
	echo "Can't find pia-config.sh at $PIA_CONFIG" >&2
	exit 1
fi

# The watchdog only needs path/interface variables, not crypto keys.
# Set dummy keys so pia-config.sh doesn't try to generate them
# (which requires wireguard-tools to be installed).
: "${CLIENT_PRIVATE_KEY:=watchdog-does-not-need-keys}"
: "${CLIENT_PUBLIC_KEY:=watchdog-does-not-need-keys}"

source "$PIA_CONFIG"

# Defaults
: "${WATCHDOG_INTERVAL:=30}"
: "${WATCHDOG_THRESHOLD:=3}"
: "${WATCHDOG_MAX_RETRY:=5}"
: "${WATCHDOG_RETRY_DELAY:=10}"
: "${PF_REFRESH_INTERVAL:=600}"

# PID file
if [ "$EUID" -eq 0 ] && [ -d /run ]; then
	WATCHDOG_PID="/run/pia-wg-watchdog.pid"
else
	WATCHDOG_PID="$CONFIGDIR/watchdog.pid"
fi

# Log file
if [ -z "$WATCHDOG_LOG" ]; then
	if [ "$EUID" -eq 0 ] && [ -d /var/log ] && [ -w /var/log ]; then
		WATCHDOG_LOG="/var/log/pia-wg-watchdog.log"
	else
		WATCHDOG_LOG="$CONFIGDIR/watchdog.log"
	fi
fi

###############################################################################
# Helper functions
###############################################################################

log_msg() {
	local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
	echo "$msg" >> "$WATCHDOG_LOG"
	# Also print to stderr if it's a terminal (useful for --daemon foreground mode)
	if [ -t 2 ]; then
		echo "$msg" >&2
	fi
}

is_running() {
	[ -f "$WATCHDOG_PID" ] && kill -0 "$(cat "$WATCHDOG_PID")" 2>/dev/null
}

###############################################################################
# Connectivity check
#
# Three-stage check:
#   1. Interface exists
#   2. WireGuard handshake within acceptable age
#   3. Ping SERVER_VIP through the PIA interface
#
# Returns 0 if connected, 1 if disconnected.
# Sets global CHECK_FAIL_REASON on failure.
###############################################################################

check_connection() {
	# Stage 1: interface exists?
	if ! ip link show "$PIA_INTERFACE" &>/dev/null; then
		CHECK_FAIL_REASON="Interface $PIA_INTERFACE does not exist"
		return 1
	fi

	# Stage 2: WireGuard handshake recency
	local handshake_age
	handshake_age=$(wg show "$PIA_INTERFACE" latest-handshakes 2>/dev/null | cut $'-d\t' -f2)
	if [ -z "$handshake_age" ] || [ "$handshake_age" -eq 0 ] 2>/dev/null; then
		CHECK_FAIL_REASON="No WireGuard handshake (never connected or stale)"
		return 1
	fi

	local max_handshake_age=$(( WATCHDOG_INTERVAL * WATCHDOG_THRESHOLD + 120 ))
	if [ "$handshake_age" -gt "$max_handshake_age" ]; then
		CHECK_FAIL_REASON="Last handshake ${handshake_age}s ago (threshold: ${max_handshake_age}s)"
		return 1
	fi

	# Stage 3: ping SERVER_VIP through PIA interface
	local server_vip
	server_vip="$(jq -r .server_vip "$REMOTEINFO" 2>/dev/null)"
	if [ -z "$server_vip" ] || [ "$server_vip" = "null" ]; then
		CHECK_FAIL_REASON="Cannot determine SERVER_VIP from $REMOTEINFO"
		return 1
	fi

	if ! ping -I "$PIA_INTERFACE" -n -w 5 -W 1 -c 3 "$server_vip" &>/dev/null; then
		CHECK_FAIL_REASON="Ping to $server_vip via $PIA_INTERFACE failed (3 packets)"
		return 1
	fi

	return 0
}

###############################################################################
# Reconnection logic
#
# Strategy:
#   1. Try fast reconnect (-f): reuse cached server, skip serverlist fetch
#   2. Try normal reconnect: re-register key with same server
#   3. Try full reconnect (-r): clear cache, possibly hop to new server
#
# After each attempt, verify connectivity before declaring success.
# If PORTFORWARD is set, re-establish port forwarding after reconnect.
#
# Returns 0 on success, 1 on failure.
###############################################################################

do_reconnect() {
	local attempt="$1"
	local max="$2"

	log_msg "RECONNECT: attempt $attempt/$max"

	# --- Stage 1: fast reconnect (same server, cached link) ---
	if [ -r "$CONNCACHE" ] && [ -r "$REMOTEINFO" ]; then
		log_msg "STAGE 1: Fast reconnect with -f (same server, cached link)"
		if "$PIA_WG" -f >> "$WATCHDOG_LOG" 2>&1; then
			sleep 3
			if check_connection; then
				log_msg "RECONNECT SUCCESS: Fast reconnect succeeded"
				handle_portforward
				return 0
			fi
			log_msg "Fast reconnect completed but connectivity check still failed"
		else
			log_msg "Fast reconnect command failed (exit $?)"
		fi
	fi

	# --- Stage 2: normal reconnect (same server, re-register key) ---
	log_msg "STAGE 2: Normal reconnect (same server, re-register key)"
	if "$PIA_WG" >> "$WATCHDOG_LOG" 2>&1; then
		sleep 5
		if check_connection; then
			log_msg "RECONNECT SUCCESS: Normal reconnect succeeded"
			handle_portforward
			return 0
		fi
		log_msg "Normal reconnect completed but connectivity check still failed"
	else
		log_msg "Normal reconnect command failed (exit $?)"
	fi

	# --- Stage 3: full reconnect (clear cache, may hop to new server) ---
	log_msg "STAGE 3: Full reconnect with -r (clear cache, may server-hop)"
	if "$PIA_WG" -r >> "$WATCHDOG_LOG" 2>&1; then
		sleep 5
		if check_connection; then
			log_msg "RECONNECT SUCCESS: Full reconnect succeeded (possible server hop)"
			handle_portforward
			return 0
		fi
		log_msg "Full reconnect completed but connectivity check still failed"
	else
		log_msg "Full reconnect command failed (exit $?)"
	fi

	return 1
}

###############################################################################
# Port forward re-establishment
###############################################################################

handle_portforward() {
	# Re-read config to get PORTFORWARD setting
	[ -r "$CONFIG" ] && source "$CONFIG"

	if [ -n "$PORTFORWARD" ]; then
		log_msg "PORTFORWARD: Re-establishing port forward"
		if [ -x "$PIA_PORTFORWARD" ]; then
			if "$PIA_PORTFORWARD" >> "$WATCHDOG_LOG" 2>&1; then
				log_msg "PORTFORWARD: Successfully re-established"
			else
				log_msg "PORTFORWARD: Failed to re-establish (exit $?)"
			fi
		else
			log_msg "PORTFORWARD: pia-portforward.sh not found or not executable at $PIA_PORTFORWARD"
		fi
	fi
}

###############################################################################
# Periodic port forward refresh (for long-running connections)
###############################################################################

maybe_refresh_portforward() {
	local now="$1"

	# Re-read config to get PORTFORWARD setting
	[ -r "$CONFIG" ] && source "$CONFIG"

	if [ -n "$PORTFORWARD" ]; then
		local elapsed=$(( now - LAST_PF_REFRESH ))
		if [ "$elapsed" -ge "$PF_REFRESH_INTERVAL" ]; then
			if [ -x "$PIA_PORTFORWARD" ]; then
				log_msg "PORTFORWARD: Periodic refresh (${elapsed}s since last refresh)"
				if "$PIA_PORTFORWARD" >> "$WATCHDOG_LOG" 2>&1; then
					log_msg "PORTFORWARD: Periodic refresh succeeded"
				else
					log_msg "PORTFORWARD: Periodic refresh failed (exit $?)"
				fi
			fi
			LAST_PF_REFRESH="$now"
		fi
	fi
}

###############################################################################
# Main watchdog loop
###############################################################################

watchdog_loop() {
	log_msg "=========================================="
	log_msg "WATCHDOG STARTED"
	log_msg "  Check interval:     ${WATCHDOG_INTERVAL}s"
	log_msg "  Failure threshold:  $WATCHDOG_THRESHOLD consecutive failures"
	log_msg "  Max reconnect tries: $WATCHDOG_MAX_RETRY"
	log_msg "  Retry delay:        ${WATCHDOG_RETRY_DELAY}s"
	log_msg "  PF refresh interval: ${PF_REFRESH_INTERVAL}s"
	log_msg "  Log file:           $WATCHDOG_LOG"
	log_msg "=========================================="

	local fail_count=0
	local LAST_PF_REFRESH
	LAST_PF_REFRESH="$(date +%s)"

	while true; do
		if check_connection; then
			# Connection is healthy
			if [ "$fail_count" -gt 0 ]; then
				log_msg "RECOVERED: Connection restored after $fail_count failure(s)"
			fi
			fail_count=0

			# Periodic portforward refresh
			maybe_refresh_portforward "$(date +%s)"
		else
			fail_count=$((fail_count + 1))
			log_msg "CHECK FAILED ($fail_count/$WATCHDOG_THRESHOLD): $CHECK_FAIL_REASON"

			if [ "$fail_count" -ge "$WATCHDOG_THRESHOLD" ]; then
				log_msg "DISCONNECTED: $WATCHDOG_THRESHOLD consecutive failures reached"
				log_msg "DISCONNECT DETAIL: reason=$CHECK_FAIL_REASON"

				# Reconnect loop with retry limit
				local reconnected=0
				local retry
				for retry in $(seq 1 "$WATCHDOG_MAX_RETRY"); do
					if do_reconnect "$retry" "$WATCHDOG_MAX_RETRY"; then
						reconnected=1
						fail_count=0
						LAST_PF_REFRESH="$(date +%s)"
						break
					fi

					if [ "$retry" -lt "$WATCHDOG_MAX_RETRY" ]; then
						log_msg "RETRY: Waiting ${WATCHDOG_RETRY_DELAY}s before next attempt"
						sleep "$WATCHDOG_RETRY_DELAY"
					fi
				done

				if [ "$reconnected" -eq 0 ]; then
					log_msg "GIVING UP: $WATCHDOG_MAX_RETRY reconnect attempts exhausted"
					log_msg "ACTION REQUIRED: Manual intervention needed to restore VPN"
					log_msg "  Try running: $PIA_WG -r"
					# Remove stale PID file so the service is shown as stopped
					rm -f "$WATCHDOG_PID"
					return 1
				fi
			fi
		fi

		sleep "$WATCHDOG_INTERVAL"
	done
}

###############################################################################
# Service management commands
###############################################################################

cmd_start() {
	if is_running; then
		echo "Watchdog already running (PID $(cat "$WATCHDOG_PID"))"
		return 0
	fi

	# Remove stale PID file
	rm -f "$WATCHDOG_PID"

	echo "Starting PIA watchdog daemon..."
	echo "  Interval: ${WATCHDOG_INTERVAL}s, Threshold: $WATCHDOG_THRESHOLD failures, Max retries: $WATCHDOG_MAX_RETRY"
	echo "  Log: $WATCHDOG_LOG"

	if command -v start-stop-daemon &>/dev/null; then
		start-stop-daemon --start --background --make-pidfile \
			--pidfile "$WATCHDOG_PID" \
			--exec /bin/bash -- "$0" --daemon
	else
		# Fallback: manual backgrounding
		(
			echo $$ > "$WATCHDOG_PID"
			watchdog_loop
			rm -f "$WATCHDOG_PID"
		) &
		local bg_pid=$!
		echo "$bg_pid" > "$WATCHDOG_PID"
		disown "$bg_pid" 2>/dev/null
	fi

	sleep 1
	if is_running; then
		echo "Watchdog started (PID $(cat "$WATCHDOG_PID"))"
	else
		echo "ERROR: Watchdog failed to start. Check $WATCHDOG_LOG for details." >&2
		return 1
	fi
}

cmd_stop() {
	if ! is_running; then
		echo "Watchdog is not running"
		rm -f "$WATCHDOG_PID"
		return 0
	fi

	local pid
	pid="$(cat "$WATCHDOG_PID")"
	echo "Stopping PIA watchdog daemon (PID $pid)..."

	if command -v start-stop-daemon &>/dev/null; then
		start-stop-daemon --stop --pidfile "$WATCHDOG_PID" --retry TERM/5/KILL/3
	else
		kill "$pid" 2>/dev/null
		local i=0
		while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do
			sleep 1
			i=$((i + 1))
		done
		# Force kill if still running
		kill -9 "$pid" 2>/dev/null
	fi

	rm -f "$WATCHDOG_PID"
	echo "Watchdog stopped"
}

cmd_status() {
	if is_running; then
		local pid
		pid="$(cat "$WATCHDOG_PID")"
		echo "PIA watchdog is running (PID $pid)"
		echo "  Log file: $WATCHDOG_LOG"
		echo "  Config:   interval=${WATCHDOG_INTERVAL}s threshold=$WATCHDOG_THRESHOLD max_retry=$WATCHDOG_MAX_RETRY"
		if [ -f "$WATCHDOG_LOG" ]; then
			echo "  Last 5 log entries:"
			tail -n 5 "$WATCHDOG_LOG" | sed 's/^/    /'
		fi
	else
		echo "PIA watchdog is not running"
		return 3  # LSB "not running" exit code
	fi
}

###############################################################################
# Main entry point
###############################################################################

case "${1:-}" in
	start)
		cmd_start
		;;
	stop)
		cmd_stop
		;;
	status)
		cmd_status
		;;
	restart)
		cmd_stop
		sleep 1
		cmd_start
		;;
	--daemon)
		# Internal: called by start-stop-daemon or manually for foreground debugging
		echo $$ > "$WATCHDOG_PID"
		watchdog_loop
		rm -f "$WATCHDOG_PID"
		;;
	*)
		echo "Usage: $(basename "$0") {start|stop|status|restart}"
		echo
		echo "  start    Start the watchdog daemon in the background"
		echo "  stop     Stop the watchdog daemon"
		echo "  status   Show watchdog daemon status and recent log"
		echo "  restart  Restart the watchdog daemon"
		echo
		echo "Configuration (set in pia-wg.conf or environment):"
		echo "  WATCHDOG_INTERVAL=$WATCHDOG_INTERVAL   Seconds between checks"
		echo "  WATCHDOG_THRESHOLD=$WATCHDOG_THRESHOLD      Consecutive failures before reconnect"
		echo "  WATCHDOG_MAX_RETRY=$WATCHDOG_MAX_RETRY       Max reconnect attempts before giving up"
		echo "  WATCHDOG_RETRY_DELAY=$WATCHDOG_RETRY_DELAY    Seconds between reconnect attempts"
		echo "  PF_REFRESH_INTERVAL=$PF_REFRESH_INTERVAL    Seconds between portforward refreshes"
		echo "  WATCHDOG_LOG=$WATCHDOG_LOG"
		exit 1
		;;
esac
