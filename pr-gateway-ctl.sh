#!/usr/bin/env bash
# pr-gateway-ctl — start/stop/status/restart the pr-gateway daemon
#
# Usage: pr-gateway-ctl {start|stop|restart|status|log}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY="$SCRIPT_DIR/pr-gateway.py"
PID_FILE="$SCRIPT_DIR/pr-gateway.pid"
LOG_FILE="$SCRIPT_DIR/pr-gateway.log"

export PR_GATEWAY_PORT="${PR_GATEWAY_PORT:-8645}"
export PR_GATEWAY_GH_PORT="${PR_GATEWAY_GH_PORT:-8646}"
export PR_GATEWAY_TARGET_URL="${PR_GATEWAY_TARGET_URL:-http://localhost:8644}"

export PR_GATEWAY_ROUTE="${PR_GATEWAY_ROUTE:-babysit-pr}"
export PR_GATEWAY_POLL_INTERVAL="${PR_GATEWAY_POLL_INTERVAL:-30}"

export PR_GATEWAY_API_BIND="${PR_GATEWAY_API_BIND:-0.0.0.0}"
export PR_GATEWAY_GH_BIND="${PR_GATEWAY_GH_BIND:-0.0.0.0}"
export GH_TOKEN_FILE="${GH_TOKEN_FILE:-~/.secrets/gh-token}"
export PR_GATEWAY_COALESCE_WINDOW="${PR_GATEWAY_COALESCE_WINDOW:-15}"
export PR_GATEWAY_AGENT_TIMEOUT="${PR_GATEWAY_AGENT_TIMEOUT:-600}"

_load_secrets() {
    # Load per-repo webhook secrets from an optional secrets file
    local secrets_file="${SECRETS_FILE:-/opt/data/.secrets/pr-gateway-webhook-secrets.env}"
    if [ -f "$secrets_file" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$secrets_file"
        set +a
    fi
    if [[ -z "${PR_GATEWAY_WEBHOOK_SECRET:-}" ]]; then
        echo "ERROR: PR_GATEWAY_WEBHOOK_SECRET is not set. Set it in your secrets file or environment." >&2
        exit 1
    fi
    export PR_GATEWAY_WEBHOOK_SECRET
}

is_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

cmd="${1:-status}"

case "$cmd" in
  start)
    _load_secrets
    if is_running; then
        echo "pr-gateway already running (pid=$(cat "$PID_FILE"))"
        exit 0
    fi
    echo "Starting pr-gateway..."
    nohup python3 "$GATEWAY" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    if is_running; then
        echo "Started (pid=$(cat "$PID_FILE"))"
    else
        echo "Failed to start — check $LOG_FILE"
        exit 1
    fi
    ;;

  stop)
    if ! is_running; then
        echo "pr-gateway not running"
        exit 0
    fi
    PID=$(cat "$PID_FILE")
    echo "Stopping pr-gateway (pid=$PID)..."
    kill "$PID"
    rm -f "$PID_FILE"
    echo "Stopped."
    ;;

  restart)
    "$0" stop || true
    sleep 1
    "$0" start
    ;;

  status)
    if is_running; then
        PID=$(cat "$PID_FILE")
        echo "pr-gateway is running (pid=$PID)"
        curl -sf "http://localhost:${PR_GATEWAY_PORT}/health" | python3 -m json.tool 2>/dev/null || true
    else
        echo "pr-gateway is NOT running"
    fi
    ;;

  log)
    tail -f "$LOG_FILE"
    ;;

  *)
    echo "Usage: $0 {start|stop|restart|status|log}"
    exit 1
    ;;
esac
