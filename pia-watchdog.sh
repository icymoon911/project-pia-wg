#!/bin/bash
# pia-watchdog.sh - PIA WireGuard connection watchdog daemon
#
# Periodically checks VPN connectivity and automatically reconnects
# if the connection is lost. Designed to be started by net.pia OpenRC
# init script (or manually) and run in the background.
#
# Detection logic:
#   Pings the connected server's VPN-IP through the PIA interface
#   every CHECK_INTERVAL seconds. Only declares a disconnect after
#   MAX_CONSECUTIVE_FAILURES consecutive ping failures, which avoids
#   false positives from transient network jitter.
#
# Reconnection logic:
#   1. Tries the cached server (pia-wg.sh -f) up to MAX_RETRIES times
#      with exponential backoff. This keeps the same server/VIP and
#      avoids unnecessary server-hopping.
#   2. If all cached attempts fail, makes one last-ditch attempt with
#      a fresh best-server selection (pia-wg.sh without -f).
#   3. If PORTFORWARD=true in pia-config.sh, re-establishes port
#      forwarding via pia-portforward.sh after a successful reconnect.
#
# Stops retrying after MAX_RETRIES + 1 total attempts to avoid
# infinite reconnection loops when PIA infrastructure is unavailable.

# Resolve script directory (follows symlinks via realpath)
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PIA_CONFIG="$SCRIPT_DIR/pia-config.sh"
PIA_WG="$SCRIPT_DIR/pia-wg.sh"
PIA_PORTFORWARD="$SCRIPT_DIR/pia-portforward.sh"

# Tunables
CHECK_INTERVAL="${PIA_WATCHDOG_INTERVAL:-30}"        # seconds between health checks
PING_COUNT=3                                         # ICMP packets per check
PING_TIMEOUT=2                                       # per-packet timeout (seconds)
PING_DEADLINE=6                                      # overall deadline for one ping run
MAX_CONSECUTIVE_FAILURES=3                           # consecutive failures before reconnect
MAX_RETRIES=5                                        # max reconnect attempts (cached server)
INITIAL_RETRY_DELAY=10                               # first retry delay (seconds)
PID_FILE="/run/pia-watchdog.pid"
LOG_FILE="/var/log/pia-watchdog.log"

# ---------- helpers ----------

log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') [pia-watchdog] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

write_pid() {
    echo $$ > "$PID_FILE"
}

cleanup() {
    log "Watchdog stopped (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

# ---------- preflight ----------

if ! [ -r "$PIA_CONFIG" ]; then
    echo "ERROR: Cannot read pia-config.sh at $PIA_CONFIG" >&2
    exit 1
fi

if ! [ -x "$PIA_WG" ]; then
    echo "ERROR: pia-wg.sh not found or not executable at $PIA_WG" >&2
    exit 1
fi

source "$PIA_CONFIG"

# ---------- reconnect logic ----------

attempt_reconnect() {
    local reason="$1"
    local delay=$INITIAL_RETRY_DELAY
    local success=0

    log "Disconnect detected: $reason"

    # Phase 1: retry with cached server (keeps same VIP, no server hopping)
    for i in $(seq 1 $MAX_RETRIES); do
        log "Reconnect attempt $i/$MAX_RETRIES (cached server, waiting ${delay}s)..."
        sleep "$delay"

        if "$PIA_WG" -f 2>&1 | tee -a "$LOG_FILE"; then
            if ip link show "$PIA_INTERFACE" >/dev/null 2>&1; then
                log "Reconnect attempt $i succeeded (cached server)"
                success=1
                break
            fi
        fi

        log "Reconnect attempt $i failed"
        delay=$((delay * 2))
    done

    # Phase 2: last-ditch attempt with fresh best-server selection
    if [ "$success" -ne 1 ]; then
        log "All cached-server attempts exhausted; trying fresh server selection..."
        sleep 5

        if "$PIA_WG" 2>&1 | tee -a "$LOG_FILE"; then
            if ip link show "$PIA_INTERFACE" >/dev/null 2>&1; then
                log "Reconnect succeeded (new server selected by latency)"
                success=1
            fi
        fi
    fi

    if [ "$success" -ne 1 ]; then
        log "ERROR: All reconnection attempts failed after $MAX_RETRIES cached + 1 fresh tries. Giving up."
        log "Manual intervention required. Run: $PIA_WG"
        return 1
    fi

    # Re-establish port forwarding if enabled
    if [ "${PORTFORWARD:-false}" = "true" ]; then
        log "Port forwarding enabled in config; re-establishing..."
        if [ -x "$PIA_PORTFORWARD" ]; then
            if "$PIA_PORTFORWARD" 2>&1 | tee -a "$LOG_FILE"; then
                log "Port forwarding re-established"
            else
                log "WARNING: Port forwarding re-establishment failed (VPN is up but inbound port may be unavailable)"
            fi
        else
            log "WARNING: pia-portforward.sh not found at $PIA_PORTFORWARD; skipping port forwarding"
        fi
    fi

    return 0
}

# ---------- signal handlers ----------

trap cleanup SIGTERM SIGINT SIGHUP

# ---------- main ----------

write_pid
log "Watchdog started (PID $$, interval=${CHECK_INTERVAL}s, threshold=$MAX_CONSECUTIVE_FAILURES consecutive failures, max_retries=$MAX_RETRIES)"

consecutive_failures=0

while true; do
    sleep "$CHECK_INTERVAL"

    # Make sure the WireGuard interface is still there
    if ! ip link show "$PIA_INTERFACE" >/dev/null 2>&1; then
        consecutive_failures=$((consecutive_failures + 1))
        if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            attempt_reconnect "Interface $PIA_INTERFACE is down (missing)"
            consecutive_failures=0
        fi
        continue
    fi

    # Resolve the server VIP from cached details
    SERVER_VIP="$(jq -r .server_vip "$REMOTEINFO" 2>/dev/null)"
    if [ -z "$SERVER_VIP" ] || [ "$SERVER_VIP" = "null" ]; then
        consecutive_failures=$((consecutive_failures + 1))
        if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            attempt_reconnect "Server VIP unavailable in $REMOTEINFO"
            consecutive_failures=0
        fi
        continue
    fi

    # Ping the server through the VPN tunnel
    if ping -I "$PIA_INTERFACE" -n -w "$PING_DEADLINE" -W "$PING_TIMEOUT" -c "$PING_COUNT" "$SERVER_VIP" >/dev/null 2>&1; then
        # Reset counter on first recovery after previous failures
        if [ "$consecutive_failures" -gt 0 ]; then
            log "Connection recovered (was failing for $consecutive_failures check(s))"
        fi
        consecutive_failures=0
    else
        consecutive_failures=$((consecutive_failures + 1))
        log "Health check failed ($consecutive_failures/$MAX_CONSECUTIVE_FAILURES): ping $SERVER_VIP via $PIA_INTERFACE"

        if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            attempt_reconnect "$MAX_CONSECUTIVE_FAILURES consecutive ping failures to $SERVER_VIP"
            consecutive_failures=0
        fi
    fi
done
