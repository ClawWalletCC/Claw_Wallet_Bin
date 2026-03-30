#!/bin/bash
set -euo pipefail

COMMAND="${1:-}"
CURRENT_VERSION="${2:-unknown}"
LATEST_VERSION="${3:-latest}"
TARGET_BIN_INPUT="${4:-}"
OLD_PID="${5:-}"

if [ "$COMMAND" != "binary-upgrade" ]; then
    echo "unknown command: $COMMAND"
    exit 1
fi

resolve_binary_name() {
    case "$(uname -s):$(uname -m)" in
        Darwin:arm64) echo "clay-sandbox-darwin-arm64" ;;
        Darwin:*) echo "clay-sandbox-darwin-amd64" ;;
        Linux:arm64|Linux:aarch64) echo "clay-sandbox-linux-arm64" ;;
        *) echo "clay-sandbox-linux-amd64" ;;
    esac
}

wait_for_pid_exit() {
    local pid="$1"
    local i
    [ -z "$pid" ] && return 0
    for i in $(seq 1 40); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

BINARY_NAME="$(resolve_binary_name)"
TARGET_BIN="${TARGET_BIN_INPUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$BINARY_NAME}"
TARGET_DIR="$(cd "$(dirname "$TARGET_BIN")" && pwd)"
LOG_FILE="$TARGET_DIR/sandbox.log"
PID_FILE="$TARGET_DIR/sandbox.pid"
UPDATE_LOG="$TARGET_DIR/sandbox-update.log"
DOWNLOAD_URL="https://github.com/ClawWallet/Claw_Wallet_Bin/raw/refs/heads/main/bin/$BINARY_NAME"
TMP_FILE="${TARGET_BIN}.download"
BACKUP_FILE="${TARGET_BIN}.bak.${CURRENT_VERSION}.$(date +%Y%m%d%H%M%S)"

mkdir -p "$TARGET_DIR"
exec >> "$UPDATE_LOG" 2>&1

echo "upgrade start current=$CURRENT_VERSION latest=$LATEST_VERSION"

rm -f "$TMP_FILE"
if ! curl -I -L --fail --connect-timeout 10 --max-time 20 "$DOWNLOAD_URL" >/dev/null; then
    echo "network check failed"
    exit 1
fi

if ! curl -L --fail --connect-timeout 15 --retry 2 --output "$TMP_FILE" "$DOWNLOAD_URL"; then
    rm -f "$TMP_FILE"
    echo "download failed"
    exit 1
fi

if [ ! -s "$TMP_FILE" ]; then
    rm -f "$TMP_FILE"
    echo "download empty"
    exit 1
fi

chmod +x "$TMP_FILE"
"$TARGET_BIN" stop >/dev/null 2>&1 || true

if ! wait_for_pid_exit "$OLD_PID"; then
    rm -f "$TMP_FILE"
    echo "stop timeout"
    exit 1
fi

rm -f "$PID_FILE"

if [ -f "$TARGET_BIN" ]; then
    cp -f "$TARGET_BIN" "$BACKUP_FILE"
fi

mv -f "$TMP_FILE" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$TARGET_BIN" serve >> "$LOG_FILE" 2>&1 < /dev/null &
else
    nohup "$TARGET_BIN" serve >> "$LOG_FILE" 2>&1 < /dev/null &
fi
echo $! > "$PID_FILE"

echo "upgrade done"
