#!/usr/bin/env bash
set -o pipefail

APP="/tmp/BBDerivedData/Build/Products/Debug-iphoneos/BigBrother.app"
BID="fr.bigbrother.app"

# Device name -> UUID mapping (works without associative arrays)
resolve_device() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')" in
        isla-iphone)  echo "DB7F2BA3-46E4-59D1-9BE1-60EAB324F183" ;;
        isla-ipad)    echo "35427EB0-3804-50B7-A069-970F7307D977" ;;
        juliet)       echo "3B6FC561-C28A-5F20-8232-E8058A24DDCE" ;;
        sebastian)    echo "C17B60F1-467D-5EC5-BA70-783D19C91249" ;;
        simon)        echo "66E78D1B-93D0-5D58-8505-DCF40709942F" ;;
        olivia)       echo "A3A7322E-9740-5388-9B4C-E99B7537F2E6" ;;
        daphne-iphone|daphne) echo "39B6646E-F780-572D-AC85-9CB24851A113" ;;
        daphne-ipad)  echo "875F45A5-CA62-515B-8C70-116B06D8021F" ;;
        me|erik|ephone) echo "4B516D91-B596-52F5-8C1D-41B14B4A1540" ;;
        *) echo "" ;;
    esac
}

ALL_NAMES=("isla-iphone" "isla-ipad" "juliet" "sebastian" "simon" "olivia" "daphne-iphone" "daphne-ipad" "me")

# Build target list
TARGETS=()
if [ $# -eq 0 ]; then
    TARGETS=("${ALL_NAMES[@]}")
else
    for arg in "$@"; do
        uuid=$(resolve_device "$arg")
        if [ -z "$uuid" ]; then
            echo "Unknown device: $arg"
            echo "Known: ${ALL_NAMES[*]}"
            exit 1
        fi
        TARGETS+=("$arg")
    done
fi

TOTAL=${#TARGETS[@]}
echo "Deploying to $TOTAL device(s): ${TARGETS[*]}"

# Phase 1: Install (retry every 5 minutes until all succeed)
declare -a INSTALL_OK
for ((i=0; i<TOTAL; i++)); do INSTALL_OK[$i]=0; done

install_attempt=0
while true; do
    install_attempt=$((install_attempt + 1))
    pending=0
    for ((i=0; i<TOTAL; i++)); do
        [ "${INSTALL_OK[$i]}" -eq 1 ] && continue
        pending=$((pending + 1))
    done
    [ "$pending" -eq 0 ] && break

    echo ""
    echo "=== INSTALL attempt $install_attempt — $pending device(s) remaining ==="

    for ((i=0; i<TOTAL; i++)); do
        [ "${INSTALL_OK[$i]}" -eq 1 ] && continue
        name="${TARGETS[$i]}"
        uuid=$(resolve_device "$name")
        result=$(xcrun devicectl device install app --device "$uuid" "$APP" 2>&1)
        if echo "$result" | grep -q "options:"; then
            INSTALL_OK[$i]=1
            echo "  ✓ $name installed"
        else
            echo "  ✗ $name install failed"
        fi
    done

    ok=0
    for ((i=0; i<TOTAL; i++)); do [ "${INSTALL_OK[$i]}" -eq 1 ] && ok=$((ok + 1)); done
    echo "Installed: $ok/$TOTAL"
    [ "$ok" -eq "$TOTAL" ] && break
    echo "Retrying installs in 5 minutes..."
    sleep 300
done

echo ""
echo "=== ALL INSTALLS COMPLETE ==="

# Phase 2: Launch (retry every minute until all succeed)
declare -a LAUNCH_OK
for ((i=0; i<TOTAL; i++)); do LAUNCH_OK[$i]=0; done

launch_attempt=0
while true; do
    launch_attempt=$((launch_attempt + 1))
    pending=0
    for ((i=0; i<TOTAL; i++)); do
        [ "${LAUNCH_OK[$i]}" -eq 1 ] && continue
        pending=$((pending + 1))
    done
    [ "$pending" -eq 0 ] && break

    echo ""
    echo "=== LAUNCH attempt $launch_attempt — $pending device(s) remaining ==="

    for ((i=0; i<TOTAL; i++)); do
        [ "${LAUNCH_OK[$i]}" -eq 1 ] && continue
        name="${TARGETS[$i]}"
        uuid=$(resolve_device "$name")
        result=$(xcrun devicectl device process launch --terminate-existing --device "$uuid" "$BID" 2>&1)
        if echo "$result" | grep -q "Launched"; then
            LAUNCH_OK[$i]=1
            echo "  ✓ $name launched"
        else
            echo "  ✗ $name launch failed (device locked?)"
        fi
    done

    ok=0
    for ((i=0; i<TOTAL; i++)); do [ "${LAUNCH_OK[$i]}" -eq 1 ] && ok=$((ok + 1)); done
    echo "Launched: $ok/$TOTAL"
    [ "$ok" -eq "$TOTAL" ] && break
    echo "Retrying launches in 60s..."
    sleep 60
done

echo ""
echo "===== FINAL REPORT ====="
for ((i=0; i<TOTAL; i++)); do
    name="${TARGETS[$i]}"
    inst="✗"; [ "${INSTALL_OK[$i]}" -eq 1 ] && inst="✓"
    launch="✗"; [ "${LAUNCH_OK[$i]}" -eq 1 ] && launch="✓"
    echo "  $inst install  $launch launch  $name"
done
