#!/usr/bin/env bash
set -o pipefail

APP="/Users/erichter/Library/Developer/Xcode/DerivedData/BigBrother-cvyasdwosjjzrccwgemgtbtnjsbw/Build/Products/Debug-iphoneos/BigBrother.app"
BID="fr.bigbrother.app"

NAMES=("Isla's iPhone" "Isla's New iPad" "Juliet's New iPad" "Sebastian's New iPad" "Simon's iPhone" "Olivia's iPhone" "Daphne's iPhone" "Daphne's iPad" "e phone")
IDS=("DB7F2BA3-46E4-59D1-9BE1-60EAB324F183" "35427EB0-3804-50B7-A069-970F7307D977" "3B6FC561-C28A-5F20-8232-E8058A24DDCE" "C17B60F1-467D-5EC5-BA70-783D19C91249" "66E78D1B-93D0-5D58-8505-DCF40709942F" "A3A7322E-9740-5388-9B4C-E99B7537F2E6" "39B6646E-F780-572D-AC85-9CB24851A113" "875F45A5-CA62-515B-8C70-116B06D8021F" "4B516D91-B596-52F5-8C1D-41B14B4A1540")

TOTAL=${#NAMES[@]}
declare -a STATUS
for ((i=0; i<TOTAL; i++)); do STATUS[$i]="pending"; done

deploy_one() {
    local idx=$1
    local did="${IDS[$idx]}"
    local name="${NAMES[$idx]}"
    local log="/tmp/deploy_${did}.log"
    echo "[$(date +%H:%M:%S)] Deploying to ${name}..." > "$log"

    if ! xcrun devicectl device install app --device "$did" "$APP" >> "$log" 2>&1; then
        echo "fail"; return 1
    fi

    # --terminate-existing kills any stale process before launching fresh
    if xcrun devicectl device process launch --terminate-existing --device "$did" "$BID" >> "$log" 2>&1; then
        echo "[$(date +%H:%M:%S)] ✓ ${name}" >> "$log"
        echo "ok"; return 0
    else
        echo "[$(date +%H:%M:%S)] ✗ ${name}" >> "$log"
        echo "fail"; return 1
    fi
}

for ((i=0; i<TOTAL; i++)); do
    rm -f "/tmp/deploy_status_${IDS[$i]}" "/tmp/deploy_${IDS[$i]}.log"
done

attempt=0
while true; do
    attempt=$((attempt + 1))
    pending=()
    for ((i=0; i<TOTAL; i++)); do
        [[ "${STATUS[$i]}" != "ok" ]] && pending+=($i)
    done
    [[ ${#pending[@]} -eq 0 ]] && break

    echo ""
    echo "=== Attempt $attempt — ${#pending[@]} device(s) remaining ==="

    pids=(); pidmap=()
    for idx in "${pending[@]}"; do
        deploy_one $idx &
        pids+=($!)
        pidmap+=($idx)
    done

    for ((j=0; j<${#pids[@]}; j++)); do
        wait ${pids[$j]}
        rc=$?
        idx=${pidmap[$j]}
        if [ $rc -eq 0 ]; then
            STATUS[$idx]="ok"
            echo "  ✓ ${NAMES[$idx]}"
        else
            STATUS[$idx]="fail"
            echo "  ✗ ${NAMES[$idx]}"
        fi
    done

    ok=0; fail=0
    for ((i=0; i<TOTAL; i++)); do
        [[ "${STATUS[$i]}" == "ok" ]] && ((ok++)) || ((fail++))
    done
    echo "Score: $ok/$TOTAL"
    [[ $fail -eq 0 ]] && break
    echo "Retrying in 60s..."
    sleep 60
done

echo ""
echo "===== FINAL REPORT ====="
for ((i=0; i<TOTAL; i++)); do
    if [[ "${STATUS[$i]}" == "ok" ]]; then
        printf "  ✓ %s\n" "${NAMES[$i]}"
    else
        printf "  ✗ %s (FAILED)\n" "${NAMES[$i]}"
    fi
done
