#!/bin/bash
# Pulls Documents/launch_log.txt from a device and prints the tail.
# Works on any paired device — pass UDID as $1 or let it auto-pick Juliet.
#
# Usage:
#   ./pull_launch_log.sh                 # defaults to Juliet's iPad
#   ./pull_launch_log.sh <UDID>
#   ./pull_launch_log.sh watch           # re-pull every 2s
#
# The log is written by StartupWatchdog (replaces earlier _LaunchLog).
# Contains:
#   - "=== Launch <date> build=<n> ===" header per launch (file truncated each launch)
#   - "cp: <name>" / "cp done: <name> (Xs)" around every main-thread risky op
#   - "[STALL #n] main silent Xs — cp=<name> cpAge=Ys" when main is blocked >750ms
#   - "DIAG: <msg>" entries from the on-screen DiagLog overlay

set -euo pipefail

BUNDLE_ID="fr.bigbrother.app"
LOG_PATH="Documents/launch_log.txt"
DEST="/tmp/bb-pull/launch_log.txt"

resolve_device() {
    local arg="${1:-}"
    if [ -n "$arg" ] && [ "$arg" != "watch" ]; then
        echo "$arg"
        return
    fi
    # Auto-pick: look for "Juliet" in the device list.
    local udid
    udid=$(xcrun devicectl list devices 2>/dev/null \
        | awk '/[Jj]uliet/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')
    if [ -z "$udid" ]; then
        echo "error: could not auto-pick Juliet — pass UDID explicitly" >&2
        xcrun devicectl list devices >&2
        exit 1
    fi
    echo "$udid"
}

WATCH=0
if [ "${1:-}" = "watch" ]; then
    WATCH=1
    DEVICE=$(resolve_device)
else
    DEVICE=$(resolve_device "${1:-}")
fi

mkdir -p "$(dirname "$DEST")"

pull_once() {
    rm -f "$DEST"
    if ! xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --user mobile \
        --source "$LOG_PATH" \
        --destination "$DEST" >/dev/null 2>&1; then
        echo "error: copy failed — is the app installed? is the device paired?" >&2
        return 1
    fi
}

print_log() {
    echo "=== $(date '+%H:%M:%S') — launch_log.txt ($(wc -l < "$DEST" | tr -d ' ') lines) ==="
    tail -60 "$DEST"
    echo ""
    echo "--- stall summary ---"
    grep -c "STALL" "$DEST" | awk '{printf "stalls: %s\n", $1}'
    grep "STALL" "$DEST" | tail -5 || true
}

if [ "$WATCH" -eq 1 ]; then
    echo "watching launch_log.txt on $DEVICE (Ctrl-C to stop)"
    while true; do
        if pull_once 2>/dev/null; then
            clear
            print_log
        fi
        sleep 2
    done
else
    pull_once
    print_log
fi
