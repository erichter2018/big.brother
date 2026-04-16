#!/usr/bin/env bash
#
# test_command_delivery.sh -- end-to-end CloudKit command delivery test
#
# Creates BBRemoteCommand records via the CloudKit REST API and polls
# BBHeartbeat records to measure the time until the target device applies
# the mode change. Reports per-transition latency and p50/p95/max stats.
#
# Unlike test_shield_cycle.sh (which uses Darwin notifications for local
# devices), this script exercises the REAL CloudKit command delivery path:
#   script -> CK REST /records/modify -> child polls CK -> applies -> heartbeat
#
# Usage:
#   ./test_command_delivery.sh                           # uses config file defaults
#   ./test_command_delivery.sh --device-id <CK_ID> --family-id <FAM_ID>
#   ./test_command_delivery.sh --device olivia           # lookup by name from config
#   ./test_command_delivery.sh --cycles 3                # 3 full cycles (default: 2)
#   ./test_command_delivery.sh --timeout 60              # poll timeout per step (default: 45s)
#
# Config file:
#   Reads familyID and deviceID from test_command_config.json in the same
#   directory. CLI flags override config values.
#
# Output:
#   - Per-step line with transition, timing, and result
#   - End-of-run summary with p50/p95/max latency
#   - JSON artifact at /tmp/bb-cmd-delivery-<unix>.json
#
# Requires: curl, jq, python3
#
# NOTE: The CK REST API public ckAPIToken may only permit reads in some
# configurations. If /records/modify returns a permission error, you may
# need a server-to-server key or authenticated session token instead.

set -o pipefail

# ── Constants ───────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${PROJECT_DIR}/test_command_config.json"

CK_API_TOKEN="${CK_API_TOKEN:-1a091d3460a9c1b488dd4259ae2f5c7bd9200ef9dd311a42c1b447da992766b7}"
CK_CONTAINER="iCloud.fr.bigbrother.app"
CK_ENV="development"
CK_HOST="https://api.apple-cloudkit.com"
CK_SUBPATH_PREFIX="/database/1/${CK_CONTAINER}/${CK_ENV}/public"
CK_BASE="${CK_HOST}${CK_SUBPATH_PREFIX}"

# Server-to-server auth (for writes). Reads still use ckAPIToken above.
CK_SERVER_KEY_ID="${CK_SERVER_KEY_ID:-42d7679baf2719d6f53559070d022dc5af6b55f6f11a4b28077d459c2b5faa0e}"
CK_SERVER_KEY_PEM="${CK_SERVER_KEY_PEM:-$HOME/eckey.pem}"

ISSUED_BY="test_command_delivery.sh@$(whoami)"

# ── Known devices (name -> CK device ID) ───────────────────────────────────
# Mirrors the device registry in test_shield_cycle.sh.

declare -a DEVICE_NAMES DEVICE_CK_IDS
add_device() { DEVICE_NAMES+=("$1"); DEVICE_CK_IDS+=("$2"); }
add_device "isla-iphone"   "08A66081-1084-44E8-8126-E3B00F536832"
add_device "isla-ipad"     "294960A0-7FC0-44D9-AA71-8F2990A2CF77"
add_device "juliet"        "B99D9B61-F760-46C3-83AA-EAA881909D85"
add_device "sebastian"     "4744FC3A-53CD-47E7-A8B2-72460A78E591"
add_device "simon"         "5968290E-B2CB-4016-882A-A0FA0FE6BF2E"
add_device "olivia"        "BED217B0-4B3E-41B4-B069-8657995000BC"
add_device "olivia-ipad"   "B690EABF-676D-49D0-A36B-370FF3C2F4E3"
add_device "daphne-iphone" "0A2405AE-83BB-437B-B0B4-9F47027B9A17"
add_device "daphne-ipad"   "21AF5BAE-C23B-451B-9DBC-B84F40CE2ED3"

lookup_device_id() {
    local name="$1"
    for ((i=0; i<${#DEVICE_NAMES[@]}; i++)); do
        if [ "${DEVICE_NAMES[$i]}" = "$name" ]; then
            echo "${DEVICE_CK_IDS[$i]}"
            return 0
        fi
    done
    return 1
}

# ── Defaults ────────────────────────────────────────────────────────────────

FAMILY_ID=""
DEVICE_ID=""
DEVICE_NAME=""
CYCLES=2
POLL_INTERVAL=2
POLL_TIMEOUT=45

# ── Read config file ───────────────────────────────────────────────────────

if [ -f "$CONFIG_FILE" ]; then
    cfg_family=$(jq -r '.familyID // empty' "$CONFIG_FILE" 2>/dev/null)
    cfg_device=$(jq -r '.deviceID // empty' "$CONFIG_FILE" 2>/dev/null)
    [ -n "$cfg_family" ] && [ "$cfg_family" != "YOUR_FAMILY_ID_HERE" ] && FAMILY_ID="$cfg_family"
    [ -n "$cfg_device" ] && [ "$cfg_device" != "YOUR_DEVICE_ID_HERE" ] && DEVICE_ID="$cfg_device"
fi

# ── CLI argument parsing ───────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --device-id ID       CloudKit device ID (UUID) to target
  --device NAME        Device name (looked up from registry or config)
  --family-id ID       Family ID (UUID) for the BBRemoteCommand record
  --cycles N           Number of full mode cycles (default: $CYCLES)
  --timeout N          Poll timeout per step in seconds (default: $POLL_TIMEOUT)
  --poll-interval N    Seconds between heartbeat polls (default: $POLL_INTERVAL)
  --dry-run            Build and print the CK payloads without sending
  -h, --help           Show this help

Config:
  Edit test_command_config.json to set defaults for familyID and deviceID
  so you don't have to pass them every time.

Cycle sequence:
  Each cycle runs: locked -> unlocked -> restricted -> unlocked
  So 2 cycles = 8 transitions.

Example:
  $(basename "$0") --device olivia --family-id ABC-123 --cycles 3
EOF
    exit 1
}

DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --device-id)      DEVICE_ID="$2"; shift 2 ;;
        --device)         DEVICE_NAME="$2"; shift 2 ;;
        --family-id)      FAMILY_ID="$2"; shift 2 ;;
        --cycles)         CYCLES="$2"; shift 2 ;;
        --timeout)        POLL_TIMEOUT="$2"; shift 2 ;;
        --poll-interval)  POLL_INTERVAL="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage ;;
        *)                echo "Unknown argument: $1"; usage ;;
    esac
done

# Resolve device name to ID if given
if [ -n "$DEVICE_NAME" ]; then
    resolved=$(lookup_device_id "$DEVICE_NAME")
    if [ -n "$resolved" ]; then
        DEVICE_ID="$resolved"
    else
        # Try the config file devices map
        resolved=$(jq -r ".devices[\"$DEVICE_NAME\"] // empty" "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$resolved" ]; then
            DEVICE_ID="$resolved"
        else
            echo "ERROR: Unknown device name '$DEVICE_NAME'"
            echo "Known devices: ${DEVICE_NAMES[*]}"
            exit 1
        fi
    fi
fi

# ── Validate inputs ────────────────────────────────────────────────────────

if [ -z "$FAMILY_ID" ]; then
    echo "ERROR: No familyID. Set it in $CONFIG_FILE or pass --family-id."
    exit 1
fi
if [ -z "$DEVICE_ID" ]; then
    echo "ERROR: No deviceID. Set it in $CONFIG_FILE or pass --device-id or --device."
    exit 1
fi

# Dependency checks
command -v curl >/dev/null    || { echo "ERROR: curl not found"; exit 1; }
command -v jq >/dev/null      || { echo "ERROR: jq not found (brew install jq)"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found"; exit 1; }

# ── Output artifact ────────────────────────────────────────────────────────

ARTIFACT="/tmp/bb-cmd-delivery-$(date +%s).json"
echo '[]' > "$ARTIFACT"

# ── Helpers ─────────────────────────────────────────────────────────────────

now_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

now_sec() {
    date +%s
}

# Generate a UUID (macOS uuidgen is available)
gen_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

# Pretty-print elapsed time
fmt_elapsed() {
    local ms="$1"
    if [ "$ms" -lt 1000 ]; then
        printf "%dms" "$ms"
    else
        local sec=$((ms / 1000))
        local rem=$((ms % 1000))
        printf "%d.%03ds" "$sec" "$rem"
    fi
}

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_step()  { printf "${CYAN}[step]${RESET}  %s\n" "$1"; }
log_ok()    { printf "${GREEN}[ok]${RESET}    %s\n" "$1"; }
log_fail()  { printf "${RED}[FAIL]${RESET}  %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[warn]${RESET}  %s\n" "$1"; }
log_info()  { printf "${BOLD}[info]${RESET}  %s\n" "$1"; }

# ── CloudKit Server-to-Server signed POST ──────────────────────────────────
#
# Args: $1=subpath (starting with /database/...)
#       $2=body (JSON string)
# Echoes: raw response body
# Exit: 0 always (caller inspects response for errors)
#
# Apple requires:
#   Signature = ECDSA-SHA256(key, "<ISO8601>:<base64(sha256(body))>:<subpath>")
#   Headers:
#     X-Apple-CloudKit-Request-KeyID
#     X-Apple-CloudKit-Request-ISO8601Date
#     X-Apple-CloudKit-Request-SignatureV1

ck_signed_post() {
    local subpath="$1"
    local body="$2"

    if [ ! -f "$CK_SERVER_KEY_PEM" ]; then
        echo "ERROR: server key PEM not found at $CK_SERVER_KEY_PEM" >&2
        return 1
    fi

    local body_file
    body_file=$(mktemp)
    # Use printf (no trailing newline) so the hash matches what curl uploads.
    printf '%s' "$body" > "$body_file"

    local body_hash
    body_hash=$(openssl dgst -sha256 -binary < "$body_file" | openssl base64 -A)

    local date_iso
    date_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local sig_input="${date_iso}:${body_hash}:${subpath}"
    local signature
    signature=$(printf '%s' "$sig_input" \
        | openssl dgst -sha256 -sign "$CK_SERVER_KEY_PEM" \
        | openssl base64 -A)

    curl -s --max-time 20 -X POST "${CK_HOST}${subpath}" \
        -H "Content-Type: application/json" \
        -H "X-Apple-CloudKit-Request-KeyID: ${CK_SERVER_KEY_ID}" \
        -H "X-Apple-CloudKit-Request-ISO8601Date: ${date_iso}" \
        -H "X-Apple-CloudKit-Request-SignatureV1: ${signature}" \
        --data-binary @"$body_file"
    local rc=$?

    rm -f "$body_file"
    return $rc
}

# ── CloudKit REST: Create BBRemoteCommand ──────────────────────────────────
#
# Creates a command record via /records/modify with forceReplace.
# Args: $1=mode (locked|unlocked|restricted)
# Echoes the commandID on success; returns non-zero on failure.

push_command() {
    local mode="$1"
    local cmd_id
    cmd_id=$(gen_uuid)
    local issued_at
    issued_at=$(now_ms)
    local expires_at=$((issued_at + 86400000))  # +24h

    local record_name="BBRemoteCommand_${cmd_id}"

    # Build the actionJSON. The Swift Codable encoding for CommandAction.setMode
    # uses {"setMode":{"_0":"<mode>"}} format.
    local action_json
    action_json=$(printf '{"setMode":{"_0":"%s"}}' "$mode")

    # Build payload using jq to ensure proper JSON escaping (especially for
    # the nested actionJSON string value and large TIMESTAMP integers).
    local payload
    payload=$(jq -n \
        --arg recordName "$record_name" \
        --arg cmdId "$cmd_id" \
        --arg famId "$FAMILY_ID" \
        --arg devId "$DEVICE_ID" \
        --arg action "$action_json" \
        --arg issuer "$ISSUED_BY" \
        --argjson issuedAt "$issued_at" \
        --argjson expiresAt "$expires_at" \
        '{
            operations: [{
                operationType: "forceReplace",
                record: {
                    recordType: "BBRemoteCommand",
                    recordName: $recordName,
                    fields: {
                        commandID:  { value: $cmdId,      type: "STRING" },
                        familyID:   { value: $famId,      type: "STRING" },
                        targetType: { value: "device",    type: "STRING" },
                        targetID:   { value: $devId,      type: "STRING" },
                        actionJSON: { value: $action,     type: "STRING" },
                        issuedBy:   { value: $issuer,     type: "STRING" },
                        issuedAt:   { value: $issuedAt,   type: "TIMESTAMP" },
                        status:     { value: "pending",   type: "STRING" },
                        expiresAt:  { value: $expiresAt,  type: "TIMESTAMP" }
                    }
                }
            }]
        }')

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "DRY RUN -- would POST to ${CK_BASE}/records/modify" >&2
        echo "$payload" | jq . >&2
        echo "$cmd_id"
        return 0
    fi

    local response
    response=$(ck_signed_post "${CK_SUBPATH_PREFIX}/records/modify" "$payload" 2>/dev/null)

    # Check for errors
    local server_err
    server_err=$(echo "$response" | jq -r '.serverErrorCode // empty' 2>/dev/null)
    if [ -n "$server_err" ]; then
        local reason
        reason=$(echo "$response" | jq -r '.reason // "unknown"' 2>/dev/null)
        echo "CK ERROR: $server_err -- $reason" >&2
        return 1
    fi

    local record_err
    record_err=$(echo "$response" | jq -r '.records[0].serverErrorCode // empty' 2>/dev/null)
    if [ -n "$record_err" ]; then
        local reason
        reason=$(echo "$response" | jq -r '.records[0].reason // "unknown"' 2>/dev/null)
        echo "CK RECORD ERROR: $record_err -- $reason" >&2
        return 1
    fi

    echo "$cmd_id"
    return 0
}

# ── CloudKit REST: Fetch BBHeartbeat ───────────────────────────────────────
#
# Uses /records/lookup (NOT /records/query) to bypass CDN cache.
# The heartbeat record name is "BBHeartbeat_<deviceID>".
# Echoes the raw JSON response.

fetch_heartbeat() {
    local url="${CK_BASE}/records/lookup?ckAPIToken=${CK_API_TOKEN}"
    local body="{\"records\":[{\"recordName\":\"BBHeartbeat_${DEVICE_ID}\"}]}"
    curl -s --max-time 15 -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null
}

# Extract a field from the heartbeat response.
hb_field() {
    local json="$1"
    local path="$2"
    echo "$json" | jq -r "${path} // empty" 2>/dev/null
}

# ── Poll for mode change ──────────────────────────────────────────────────
#
# Polls the heartbeat until currentMode matches the expected value or timeout.
# Args: $1=expected_mode
# Returns: 0 on success, 1 on timeout
# Sets globals: POLL_ELAPSED_MS

POLL_ELAPSED_MS=0
POLL_APPLY_MS=0        # push_time_ms → hbLastCmdAt (true delivery latency)
POLL_HB_LAG_MS=0       # hbLastCmdAt → heartbeat timestamp (upload lag)

# Poll until the device's heartbeat reports that OUR specific commandID was
# the last one processed. This is unambiguous: if lastCommandID matches the
# cmd_id we pushed, our command landed, full stop.
#
# Args: $1=expected_mode, $2=expected_cmd_id, $3=push_time_ms
# Returns 0 on match, 1 on timeout.
#
# Emits:
#   POLL_ELAPSED_MS  — push → heartbeat-readable (includes hb upload + CK index)
#   POLL_APPLY_MS    — push → device-side apply time (hbLastCmdAt - push_time)
#   POLL_HB_LAG_MS   — hbLastCmdAt → heartbeat.timestamp (upload + index lag)
poll_for_cmd_applied() {
    local expected_mode="$1"
    local expected_cmd_id="$2"
    local push_ms="$3"

    local start_sec
    start_sec=$(now_sec)
    local start_ms
    start_ms=$(now_ms)
    local deadline=$((start_sec + POLL_TIMEOUT))

    while true; do
        local now
        now=$(now_sec)
        if [ "$now" -ge "$deadline" ]; then
            POLL_ELAPSED_MS=$(( (now - start_sec) * 1000 ))
            POLL_APPLY_MS=0
            POLL_HB_LAG_MS=0
            return 1
        fi

        local hb_json
        hb_json=$(fetch_heartbeat)

        local current_mode last_cmd_id last_cmd_at hb_ts hb_source
        current_mode=$(hb_field "$hb_json" '.records[0].fields.currentMode.value')
        last_cmd_id=$(hb_field "$hb_json" '.records[0].fields.hbLastCmdID.value')
        last_cmd_at=$(hb_field "$hb_json" '.records[0].fields.hbLastCmdAt.value')
        hb_ts=$(hb_field "$hb_json" '.records[0].fields.timestamp.value')
        hb_source=$(hb_field "$hb_json" '.records[0].fields.hbSource.value')

        if [ "$last_cmd_id" = "$expected_cmd_id" ]; then
            # Export source so run_transition can display which path handled it.
            POLL_SOURCE="$hb_source"
            local end_ms
            end_ms=$(now_ms)
            POLL_ELAPSED_MS=$((end_ms - start_ms))
            if [ -n "$last_cmd_at" ] && [ "$last_cmd_at" -gt 0 ] 2>/dev/null; then
                POLL_APPLY_MS=$((last_cmd_at - push_ms))
                if [ -n "$hb_ts" ] && [ "$hb_ts" -gt 0 ] 2>/dev/null; then
                    POLL_HB_LAG_MS=$((hb_ts - last_cmd_at))
                fi
            fi
            # Warn (non-fatal) if mode on heartbeat doesn't match target.
            # Could mean a concurrent schedule transition, or the mode was
            # superseded between apply and heartbeat upload.
            if [ "$current_mode" != "$expected_mode" ]; then
                log_warn "  cmd applied but heartbeat mode=$current_mode (expected $expected_mode)"
            fi
            return 0
        fi

        sleep "$POLL_INTERVAL"
    done
}

# ── Record result to artifact ──────────────────────────────────────────────

append_result() {
    local mode="$1"
    local elapsed_ms="$2"
    local status="$3"
    local cmd_id="$4"

    local tmp
    tmp=$(mktemp)
    jq --arg mode "$mode" \
       --argjson elapsed "$elapsed_ms" \
       --arg status "$status" \
       --arg cmd_id "$cmd_id" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '. += [{"mode": $mode, "elapsed_ms": $elapsed, "status": $status, "commandID": $cmd_id, "timestamp": $ts}]' \
       "$ARTIFACT" > "$tmp" && mv "$tmp" "$ARTIFACT"
}

# ── Run a single transition ────────────────────────────────────────────────
#
# Args: $1=step_number, $2=target_mode
# Returns 0 on success, 1 on failure.

ALL_LATENCIES=()  # total push → heartbeat-observable
ALL_APPLY_MS=()   # push → hbLastCmdAt (true command-apply latency)
ALL_HB_LAG_MS=()  # hbLastCmdAt → heartbeat.timestamp (upload+index lag)
PASS_COUNT=0
FAIL_COUNT=0

run_transition() {
    local step="$1"
    local target_mode="$2"
    local total="$3"

    log_step "[$step/$total] setMode -> $target_mode"

    # 1. Record push time, then push the command
    local push_ms
    push_ms=$(now_ms)
    local cmd_id
    cmd_id=$(push_command "$target_mode")
    local push_rc=$?

    if [ $push_rc -ne 0 ]; then
        log_fail "[$step/$total] Failed to push command ($target_mode)"
        append_result "$target_mode" 0 "push_failed" ""
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_ok "[$step/$total] DRY RUN: would wait for $target_mode (cmd=$cmd_id)"
        return 0
    fi

    # 2. Poll for OUR specific cmd_id to appear as hbLastCmdID on the heartbeat.
    if poll_for_cmd_applied "$target_mode" "$cmd_id" "$push_ms"; then
        local pretty_total pretty_apply pretty_hb
        pretty_total=$(fmt_elapsed "$POLL_ELAPSED_MS")
        if [ "$POLL_APPLY_MS" -gt 0 ] 2>/dev/null; then
            pretty_apply=$(fmt_elapsed "$POLL_APPLY_MS")
            pretty_hb=$(fmt_elapsed "$POLL_HB_LAG_MS")
            local src_tag="${POLL_SOURCE:-?}"
            log_ok "[$step/$total] $target_mode confirmed via=$src_tag | total=$pretty_total apply=$pretty_apply hb-lag=$pretty_hb (cmd=$cmd_id)"
        else
            log_ok "[$step/$total] $target_mode confirmed in $pretty_total (cmd=$cmd_id — apply time unavailable, likely older build)"
        fi
        append_result "$target_mode" "$POLL_ELAPSED_MS" "pass" "$cmd_id"
        ALL_LATENCIES+=("$POLL_ELAPSED_MS")
        if [ "$POLL_APPLY_MS" -gt 0 ] 2>/dev/null; then
            ALL_APPLY_MS+=("$POLL_APPLY_MS")
            ALL_HB_LAG_MS+=("$POLL_HB_LAG_MS")
        fi
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        log_fail "[$step/$total] TIMEOUT waiting for cmd=$cmd_id after ${POLL_TIMEOUT}s"
        append_result "$target_mode" "$((POLL_TIMEOUT * 1000))" "timeout" "$cmd_id"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

# ── Statistics ──────────────────────────────────────────────────────────────

compute_stats() {
    local -a latencies=("$@")
    local count=${#latencies[@]}

    if [ "$count" -eq 0 ]; then
        echo "No successful transitions to compute stats."
        return
    fi

    # Use python3 for percentile computation (bash sort + index is fragile)
    local csv
    csv=$(IFS=,; echo "${latencies[*]}")

    python3 <<PYEOF
import statistics

raw = [${csv}]
raw.sort()
n = len(raw)

def percentile(data, p):
    k = (n - 1) * p / 100
    f = int(k)
    c = f + 1
    if c >= n:
        return data[-1]
    return data[f] + (k - f) * (data[c] - data[f])

p50 = percentile(raw, 50)
p95 = percentile(raw, 95)
mx  = max(raw)
mn  = min(raw)
avg = statistics.mean(raw)

def fmt(ms):
    if ms < 1000:
        return f"{int(ms)}ms"
    return f"{ms/1000:.2f}s"

print(f"  Samples:  {n}")
print(f"  Min:      {fmt(mn)}")
print(f"  p50:      {fmt(p50)}")
print(f"  p95:      {fmt(p95)}")
print(f"  Max:      {fmt(mx)}")
print(f"  Mean:     {fmt(avg)}")
PYEOF
}

# ── Pre-flight: check current heartbeat ────────────────────────────────────

preflight() {
    log_info "Target device: ${DEVICE_NAME:-$DEVICE_ID}"
    log_info "Family ID:     $FAMILY_ID"
    log_info "Cycles:        $CYCLES ($(( CYCLES * 4 )) transitions)"
    log_info "Poll timeout:  ${POLL_TIMEOUT}s"
    log_info "Artifact:      $ARTIFACT"
    echo ""

    log_step "Pre-flight: fetching current heartbeat..."
    local hb_json
    hb_json=$(fetch_heartbeat)

    local current_mode
    current_mode=$(hb_field "$hb_json" '.records[0].fields.currentMode.value')
    local build
    build=$(hb_field "$hb_json" '.records[0].fields.hbAppBuildNumber.value')
    local last_seen
    last_seen=$(hb_field "$hb_json" '.records[0].fields.timestamp.value')

    if [ -z "$current_mode" ]; then
        local err
        err=$(hb_field "$hb_json" '.records[0].serverErrorCode')
        if [ -n "$err" ]; then
            log_fail "No heartbeat found for device $DEVICE_ID (error: $err)"
        else
            log_fail "No heartbeat found for device $DEVICE_ID"
        fi
        echo "  Raw response:"
        echo "$hb_json" | jq . 2>/dev/null || echo "$hb_json"
        exit 1
    fi

    # Convert lastSeen timestamp (ms since epoch) to human-readable
    local last_seen_human=""
    if [ -n "$last_seen" ]; then
        local last_seen_sec=$((last_seen / 1000))
        local now_s
        now_s=$(now_sec)
        local age_sec=$((now_s - last_seen_sec))
        if [ "$age_sec" -lt 60 ]; then
            last_seen_human="${age_sec}s ago"
        elif [ "$age_sec" -lt 3600 ]; then
            last_seen_human="$((age_sec / 60))m ago"
        else
            last_seen_human="$((age_sec / 3600))h ago"
        fi
    fi

    log_ok "Device: ${DEVICE_NAME:-$DEVICE_ID} | Mode: $current_mode | Build: ${build:-?} | Last heartbeat: ${last_seen_human:-unknown}"
    echo ""

    # Warn if device is stale
    if [ -n "$last_seen" ]; then
        local last_seen_sec=$((last_seen / 1000))
        local now_s
        now_s=$(now_sec)
        local age_sec=$((now_s - last_seen_sec))
        if [ "$age_sec" -gt 300 ]; then
            log_warn "Device heartbeat is ${age_sec}s old. Device may be offline."
            log_warn "Commands will queue but latency will reflect device wake time."
            echo ""
        fi
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    echo ""
    printf "${BOLD}=== Big.Brother Command Delivery Test ===${RESET}\n"
    echo ""

    preflight

    # Each cycle: locked -> unlocked -> restricted -> unlocked
    local step=0
    local total=$((CYCLES * 4))
    local cycle_modes=("locked" "unlocked" "restricted" "unlocked")

    printf "${BOLD}--- Starting %d cycles (%d transitions) ---${RESET}\n\n" "$CYCLES" "$total"

    for ((c=1; c<=CYCLES; c++)); do
        log_info "Cycle $c/$CYCLES"
        for mode in "${cycle_modes[@]}"; do
            step=$((step + 1))
            run_transition "$step" "$mode" "$total"

            # Brief pause between transitions to avoid burst-related confusion
            if [ "$step" -lt "$total" ] && [ "$DRY_RUN" -eq 0 ]; then
                sleep 2
            fi
        done
        echo ""
    done

    # ── Summary ─────────────────────────────────────────────────────────────

    printf "${BOLD}=== Results ===${RESET}\n\n"
    log_info "Pass: $PASS_COUNT / $((PASS_COUNT + FAIL_COUNT))"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        log_fail "Fail: $FAIL_COUNT"
    fi
    echo ""

    if [ ${#ALL_LATENCIES[@]} -gt 0 ]; then
        printf "${BOLD}Total latency (push → heartbeat readable):${RESET}\n"
        compute_stats "${ALL_LATENCIES[@]}"
        echo ""

        if [ ${#ALL_APPLY_MS[@]} -gt 0 ]; then
            printf "${BOLD}Apply latency (push → device applied, from hbLastCmdAt):${RESET}\n"
            compute_stats "${ALL_APPLY_MS[@]}"
            echo ""

            printf "${BOLD}Heartbeat lag (apply → heartbeat uploaded):${RESET}\n"
            compute_stats "${ALL_HB_LAG_MS[@]}"
            echo ""
        fi

        # Per-mode breakdown
        for mode in locked unlocked restricted; do
            local -a mode_lats=()
            local entries
            entries=$(jq -r ".[] | select(.mode == \"$mode\" and .status == \"pass\") | .elapsed_ms" "$ARTIFACT" 2>/dev/null)
            while IFS= read -r val; do
                [ -n "$val" ] && mode_lats+=("$val")
            done <<< "$entries"

            if [ ${#mode_lats[@]} -gt 0 ]; then
                printf "${BOLD}  -> $mode:${RESET}\n"
                compute_stats "${mode_lats[@]}" | sed 's/^/    /'
            fi
        done
        echo ""
    fi

    log_info "Artifact saved: $ARTIFACT"
    echo ""
}

main
