#!/usr/bin/env bash
# Monitor Juliet's heartbeat mode via CK REST reads.
# Run this, send commands from parent, see delivery timing.

API="https://api.apple-cloudkit.com/database/1/iCloud.fr.bigbrother.app/development/public"
TOKEN="1a091d3460a9c1b488dd4259ae2f5c7bd9200ef9dd311a42c1b447da992766b7"
FAMILY="7B7AFBD6-749F-4B43-93F8-308539613B95"
DEVICE="${1:-B99D9B61-F760-46C3-83AA-EAA881909D85}"
INTERVAL="${2:-3}"

last_mode=""
last_change=$(date +%s)

echo "Monitoring device ${DEVICE:0:8}... (poll every ${INTERVAL}s)"
echo "Send commands from parent. Ctrl-C to stop."
echo "---"

while true; do
    result=$(curl -s -X POST "${API}/records/query?ckAPIToken=${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":{\"recordType\":\"BBHeartbeat\",\"filterBy\":[{\"fieldName\":\"deviceID\",\"comparator\":\"EQUALS\",\"fieldValue\":{\"value\":\"${DEVICE}\",\"type\":\"STRING\"}},{\"fieldName\":\"familyID\",\"comparator\":\"EQUALS\",\"fieldValue\":{\"value\":\"${FAMILY}\",\"type\":\"STRING\"}}]},\"resultsLimit\":1}" 2>/dev/null)

    mode=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['records'][0]['fields']['currentMode']['value'])" 2>/dev/null)
    build=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['records'][0]['fields'].get('hbAppBuildNumber',{}).get('value','?'))" 2>/dev/null)
    ts=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['records'][0]['fields']['timestamp']['value'])" 2>/dev/null)

    if [ -z "$mode" ]; then
        echo "$(date +%H:%M:%S) [ERROR] No heartbeat returned"
        sleep "$INTERVAL"
        continue
    fi

    now=$(date +%s)
    if [ "$mode" != "$last_mode" ] && [ -n "$last_mode" ]; then
        elapsed=$((now - last_change))
        echo "$(date +%H:%M:%S) MODE CHANGED: $last_mode → $mode (${elapsed}s since last change) build=$build"
        last_change=$now
    fi

    if [ -z "$last_mode" ]; then
        echo "$(date +%H:%M:%S) Current mode: $mode build=$build"
        last_mode="$mode"
    fi

    last_mode="$mode"
    sleep "$INTERVAL"
done
