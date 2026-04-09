#!/usr/bin/env bash
set -o pipefail

# Deploy Big Brother to all (or specified) devices.
# Usage:
#   ./deploy_everywhere.sh              # all 9 devices
#   ./deploy_everywhere.sh olivia me    # just those two
#   ./deploy_everywhere.sh --no-build   # skip build, use last .app
#
# Three phases:
#   1. Clean build (xcodebuild) — ensures all extensions are rebuilt
#   2. Install + Launch — retries until all reachable devices are running
#   3. Heartbeat — polls CloudKit until each child device confirms the new build

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

BUILD_DIR="/tmp/bb-deploy"
BID="fr.bigbrother.app"

# CloudKit API token for heartbeat verification (public database, read-only).
CK_API_TOKEN="${CK_API_TOKEN:-1a091d3460a9c1b488dd4259ae2f5c7bd9200ef9dd311a42c1b447da992766b7}"
CK_CONTAINER="iCloud.fr.bigbrother.app"
CK_ENV="development"

RETRY_INTERVAL=300   # 5 minutes between install retries
LAUNCH_INTERVAL=60   # 1 minute between launch/heartbeat retries

# Device registry — parallel arrays (bash 3.x compatible, no associative arrays)
ALL_NAMES=()
ALL_XCODE_IDS=()
ALL_CK_IDS=()
ALL_IS_PARENT=()

add_device() {
    ALL_NAMES+=("$1")
    ALL_XCODE_IDS+=("$2")
    ALL_CK_IDS+=("$3")
    ALL_IS_PARENT+=("${4:-0}")
}

add_device "isla-iphone"    "DB7F2BA3-46E4-59D1-9BE1-60EAB324F183" "08A66081-1084-44E8-8126-E3B00F536832"
add_device "isla-ipad"      "35427EB0-3804-50B7-A069-970F7307D977" "294960A0-7FC0-44D9-AA71-8F2990A2CF77"
add_device "juliet"         "3B6FC561-C28A-5F20-8232-E8058A24DDCE" "B99D9B61-F760-46C3-83AA-EAA881909D85"
add_device "sebastian"      "C17B60F1-467D-5EC5-BA70-783D19C91249" "4744FC3A-53CD-47E7-A8B2-72460A78E591"
add_device "simon"          "66E78D1B-93D0-5D58-8505-DCF40709942F" "5968290E-B2CB-4016-882A-A0FA0FE6BF2E"
add_device "olivia"         "A3A7322E-9740-5388-9B4C-E99B7537F2E6" "BED217B0-4B3E-41B4-B069-8657995000BC"
add_device "daphne-iphone"  "39B6646E-F780-572D-AC85-9CB24851A113" "0A2405AE-83BB-437B-B0B4-9F47027B9A17"
add_device "daphne-ipad"    "875F45A5-CA62-515B-8C70-116B06D8021F" "21AF5BAE-C23B-451B-9DBC-B84F40CE2ED3"
add_device "me"             "4B516D91-B596-52F5-8C1D-41B14B4A1540" "" "1"

DEVICE_COUNT=${#ALL_NAMES[@]}

# Lookup helpers
find_device_index() {
    local name="$1"
    for ((i=0; i<DEVICE_COUNT; i++)); do
        [ "${ALL_NAMES[$i]}" = "$name" ] && echo "$i" && return
    done
    echo "-1"
}

# Parse args
NO_BUILD=false
TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=true ;;
        *)
            key=$(echo "$arg" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
            case "$key" in
                ephone|erik|e-phone) key="me" ;;
                daphne) key="daphne-iphone" ;;
            esac
            idx=$(find_device_index "$key")
            if [ "$idx" = "-1" ]; then
                echo "Unknown device: $arg"
                echo "Known: ${ALL_NAMES[*]}"
                exit 1
            fi
            TARGETS+=("$key")
            ;;
    esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=("${ALL_NAMES[@]}")

TOTAL=${#TARGETS[@]}
BUILD_NUM=$(grep 'appBuildNumber' "$PROJECT_DIR/BigBrotherCore/Sources/BigBrotherCore/Constants/AppConstants.swift" | grep -o '[0-9]*')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Big Brother Deploy  b${BUILD_NUM} · $(date '+%H:%M') · ${TOTAL} device(s)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Phase 0: Build ────────────────────────────────────────────────────────────
if ! $NO_BUILD; then
    echo "Building b${BUILD_NUM}..."
    BUILD_START=$(date +%s)
    rm -rf "$BUILD_DIR" 2>/dev/null || true
    xattr -cr "$PROJECT_DIR" 2>/dev/null || true
    BUILD_LOG=$(mktemp)
    if ! xcodebuild -project BigBrother.xcodeproj \
        -scheme BigBrother \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$BUILD_DIR" \
        -quiet \
        build >"$BUILD_LOG" 2>&1; then
        echo "Build failed:"
        cat "$BUILD_LOG"
        rm -f "$BUILD_LOG"
        exit 1
    fi
    rm -f "$BUILD_LOG"
    BUILD_END=$(date +%s)
    BUILD_SECS=$((BUILD_END - BUILD_START))
    echo "Build OK (${BUILD_SECS}s)"
else
    echo "Skipping build (--no-build)"
fi

APP=$(find "$BUILD_DIR" -name "BigBrother.app" -path "*/Debug-iphoneos/*" | head -1)
if [ -z "$APP" ]; then
    echo "ERROR: Can't find .app bundle in $BUILD_DIR"
    echo "Run without --no-build first."
    exit 1
fi

DEPLOY_START=$(date +%s)
echo ""

# Per-target status arrays (indexed same as TARGETS)
INSTALL_OK=()
LAUNCH_OK=()
HB_CONFIRMED=()
for ((i=0; i<TOTAL; i++)); do
    INSTALL_OK[$i]=0
    LAUNCH_OK[$i]=0
    # Auto-confirm parent devices
    idx=$(find_device_index "${TARGETS[$i]}")
    if [ "${ALL_IS_PARENT[$idx]}" = "1" ]; then
        HB_CONFIRMED[$i]=1
    else
        HB_CONFIRMED[$i]=0
    fi
done

# ── Phase 1+2: Install & Launch (interleaved) ──────────────────────────────
# Install retries every 5 minutes. Launch attempts every minute for installed devices.
# Devices that install successfully get launched immediately without waiting for others.
install_attempt=0
last_install_time=0

while true; do
    now=$(date +%s)

    # Count pending
    install_pending=0
    launch_pending=0
    for ((i=0; i<TOTAL; i++)); do
        [ "${INSTALL_OK[$i]}" -eq 0 ] && install_pending=$((install_pending + 1))
        [ "${INSTALL_OK[$i]}" -eq 1 ] && [ "${LAUNCH_OK[$i]}" -eq 0 ] && launch_pending=$((launch_pending + 1))
    done

    # All done?
    [ "$install_pending" -eq 0 ] && [ "$launch_pending" -eq 0 ] && break

    # Install attempt (every 5 minutes or first time)
    if [ "$install_pending" -gt 0 ] && [ $((now - last_install_time)) -ge $RETRY_INTERVAL -o "$install_attempt" -eq 0 ]; then
        install_attempt=$((install_attempt + 1))
        if [ "$install_pending" -gt 0 ]; then
            echo "=== INSTALL attempt $install_attempt — $install_pending device(s) remaining ==="
            for ((i=0; i<TOTAL; i++)); do
                [ "${INSTALL_OK[$i]}" -ne 0 ] && continue
                name="${TARGETS[$i]}"
                idx=$(find_device_index "$name")
                uuid="${ALL_XCODE_IDS[$idx]}"
                result=$(xcrun devicectl device install app --device "$uuid" "$APP" 2>&1)
                if echo "$result" | grep -q "options:"; then
                    INSTALL_OK[$i]=1
                    echo "  + $name installed"
                else
                    echo "  x $name install failed"
                fi
            done
            ok=0
            for ((i=0; i<TOTAL; i++)); do [ "${INSTALL_OK[$i]}" -eq 1 ] && ok=$((ok + 1)); done
            echo "Installed: $ok/$TOTAL"
            last_install_time=$(date +%s)
        fi
    fi

    # Launch any installed-but-not-launched devices (once each)
    if [ "$launch_pending" -gt 0 ]; then
        for ((i=0; i<TOTAL; i++)); do
            [ "${INSTALL_OK[$i]}" -ne 1 ] && continue
            [ "${LAUNCH_OK[$i]}" -eq 1 ] && continue
            name="${TARGETS[$i]}"
            idx=$(find_device_index "$name")
            uuid="${ALL_XCODE_IDS[$idx]}"
            if xcrun devicectl device process launch --device "$uuid" "$BID" >/dev/null 2>&1; then
                LAUNCH_OK[$i]=1
                echo "  + $name launched"
            else
                echo "  x $name launch failed (will retry)"
            fi
        done
    fi

    # Check if we're done
    all_done=1
    for ((i=0; i<TOTAL; i++)); do
        if [ "${INSTALL_OK[$i]}" -eq 0 ] || ([ "${INSTALL_OK[$i]}" -eq 1 ] && [ "${LAUNCH_OK[$i]}" -eq 0 ]); then
            all_done=0
            break
        fi
    done
    [ "$all_done" -eq 1 ] && break

    sleep $LAUNCH_INTERVAL
done

echo ""
echo "=== ALL INSTALLS & LAUNCHES COMPLETE ==="
echo ""


# ── Phase 3: Heartbeat verification ──────────────────────────────────────────
echo "Waiting for heartbeat confirmation (b${BUILD_NUM})..."
echo ""

hb_attempt=0
while true; do
    hb_attempt=$((hb_attempt + 1))

    # Check if all confirmed
    all_done=true
    for ((i=0; i<TOTAL; i++)); do
        [ "${HB_CONFIRMED[$i]}" -ne 1 ] && all_done=false && break
    done
    $all_done && break

    # Query CloudKit
    ck_url="https://api.apple-cloudkit.com/database/1/${CK_CONTAINER}/${CK_ENV}/public/records/query?ckAPIToken=${CK_API_TOKEN}"
    response=$(curl -s --max-time 15 -X POST "$ck_url" \
        -H "Content-Type: application/json" \
        -d '{
            "query": {
                "recordType": "BBHeartbeat",
                "filterBy": [{
                    "fieldName": "timestamp",
                    "comparator": "GREATER_THAN",
                    "fieldValue": {"value": 0, "type": "TIMESTAMP"}
                }]
            },
            "resultsLimit": 50
        }' 2>/dev/null) || true

    deploy_ms=$((DEPLOY_START * 1000))

    if [ -n "$response" ] && ! echo "$response" | grep -q '"serverErrorCode"'; then
        hb_data=$(echo "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for rec in data.get('records', []):
    f = rec.get('fields', {})
    did = f.get('deviceID', {}).get('value', '')
    build = f.get('hbAppBuildNumber', {}).get('value', 0)
    ts = f.get('timestamp', {}).get('value', 0)
    if did and not did.startswith('SchemaSeed'):
        print(f'{did} {build} {ts}')
" 2>/dev/null) || true

        for ((i=0; i<TOTAL; i++)); do
            [ "${HB_CONFIRMED[$i]}" -eq 1 ] && continue
            name="${TARGETS[$i]}"
            idx=$(find_device_index "$name")
            ck_id="${ALL_CK_IDS[$idx]}"
            [ -z "$ck_id" ] && continue
            hb_line=$(echo "$hb_data" | grep "^${ck_id} " 2>/dev/null)
            [ -z "$hb_line" ] && continue
            hb_build=$(echo "$hb_line" | awk '{print $2}')
            hb_ts=$(echo "$hb_line" | awk '{print $3}')
            if [ "$hb_build" = "$BUILD_NUM" ] && [ "$hb_ts" -gt "$deploy_ms" ] 2>/dev/null; then
                HB_CONFIRMED[$i]=1
                echo "  + $name heartbeat confirmed b${BUILD_NUM}"
            fi
        done
    fi

    # Recount
    confirmed=0
    for ((i=0; i<TOTAL; i++)); do [ "${HB_CONFIRMED[$i]}" -eq 1 ] && confirmed=$((confirmed + 1)); done
    remaining=$((TOTAL - confirmed))

    all_done=true
    for ((i=0; i<TOTAL; i++)); do
        [ "${HB_CONFIRMED[$i]}" -ne 1 ] && all_done=false && break
    done
    $all_done && break

    echo "  ($confirmed/$TOTAL confirmed, $remaining remaining — retry in ${LAUNCH_INTERVAL}s)"
    sleep $LAUNCH_INTERVAL
done

echo ""
echo "===== FINAL REPORT ====="
for ((i=0; i<TOTAL; i++)); do
    name="${TARGETS[$i]}"
    inst="x"; [ "${INSTALL_OK[$i]}" -eq 1 ] && inst="+"
    launch="x"; [ "${LAUNCH_OK[$i]}" -eq 1 ] && launch="+"
    hb="x"; [ "${HB_CONFIRMED[$i]}" -eq 1 ] && hb="+"
    echo "  $inst install  $launch launch  $hb heartbeat  $name"
done
echo ""
