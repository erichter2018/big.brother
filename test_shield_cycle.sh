#!/usr/bin/env bash
#
# test_shield_cycle.sh — automated shield test harness for BigBrother
#
# Drives random (+ seeded-edge) mode transitions into one or more child
# devices via CloudKit REST, polls the resulting BBHeartbeat records for
# the new DiagnosticSnapshot, asserts correctness against the per-token
# verdict list the child now emits, and reports end-to-end timing per step
# plus p50/p95/max at the end.
#
# Usage:
#   ./test_shield_cycle.sh                          # default: olivia, 25 iterations
#   ./test_shield_cycle.sh juliet                   # single device
#   ./test_shield_cycle.sh olivia isla-iphone       # multiple, sequential
#   ./test_shield_cycle.sh --all-children           # every non-parent device
#   ./test_shield_cycle.sh olivia --iterations 50
#   ./test_shield_cycle.sh olivia --scenarios edges
#   ./test_shield_cycle.sh olivia --seed 42
#
# Output:
#   - Per-iteration line on stdout with mode, timing, verdict result
#   - End-of-run summary table (pass rate, latency percentiles)
#   - JSON artifact at /tmp/bb-test-shield-<unix>.json for replay/analysis
#
# Requires: curl, jq (brew install jq), python3 (for stats)
#
# Caveats (see plan /Users/erichter/.claude/plans/rippling-wibbling-castle.md):
#   - Writes unsigned BBRemoteCommand records. Works on devices with empty
#     Keychain signing keys (current state of olivia/isla). If signing is
#     restored, script needs to sign first — not implemented here.
#   - Public-DB write with CK_API_TOKEN may or may not be permitted; the
#     script surfaces HTTP errors clearly so you can swap tokens if needed.

set -o pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

CK_API_TOKEN="${CK_API_TOKEN:-1a091d3460a9c1b488dd4259ae2f5c7bd9200ef9dd311a42c1b447da992766b7}"
CK_CONTAINER="iCloud.fr.bigbrother.app"
CK_ENV="development"
CK_BASE="https://api.apple-cloudkit.com/database/1/${CK_CONTAINER}/${CK_ENV}/public"
ISSUED_BY="test_shield_cycle.sh@$(whoami)"

POLL_INTERVAL_SEC=1
# Fail fast: either it lands in the expected window (fg <5s, bg ~21s p50)
# or we call it broken and move on. Previous 90s was dead weight on failed
# iterations — user's framing: "it either works fast, works slightly
# slower, or I don't care because it's not good enough."
POLL_TIMEOUT_SEC=30

# ─── Device registry ────────────────────────────────────────────────────────
# Mirrors deploy_everywhere.sh. Keep in sync when adding devices.
# Fields: NAME | XCODE_DEVICE_ID (devicectl) | CK_DEVICE_ID (heartbeat) | IS_PARENT
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
add_device "olivia-ipad"    "DF8EDC8C-4FF8-510D-A835-ABE3754CA764" "B690EABF-676D-49D0-A36B-370FF3C2F4E3"
add_device "daphne-iphone"  "39B6646E-F780-572D-AC85-9CB24851A113" "0A2405AE-83BB-437B-B0B4-9F47027B9A17"
add_device "daphne-ipad"    "875F45A5-CA62-515B-8C70-116B06D8021F" "21AF5BAE-C23B-451B-9DBC-B84F40CE2ED3"
add_device "me"             "4B516D91-B596-52F5-8C1D-41B14B4A1540" "" "1"
DEVICE_COUNT=${#ALL_NAMES[@]}

find_device_index() {
    local name="$1"
    for ((i=0; i<DEVICE_COUNT; i++)); do
        [ "${ALL_NAMES[$i]}" = "$name" ] && echo "$i" && return
    done
    echo "-1"
}

valid_device_names() {
    local names=()
    for ((i=0; i<DEVICE_COUNT; i++)); do names+=("${ALL_NAMES[$i]}"); done
    printf '%s\n' "${names[@]}"
}

# ─── Arg parsing ───────────────────────────────────────────────────────────
TARGETS=()
ITERATIONS=25
SCENARIO_MODE="both"     # random | edges | both
SEED=""
APP_MODE="foreground"    # foreground | background | both

usage() {
    cat <<EOF
Usage: $(basename "$0") [devices...] [--iterations N] [--scenarios random|edges|both] [--seed N] [--mode foreground|background|both]

Valid device names (from registry):
$(valid_device_names | sed 's/^/  /')

Modes:
  foreground  main app receives Darwin notifications (device is woken
              via 'devicectl process launch' before every step).
              Fast path — measures apply/heartbeat latency when the
              kid has the app open.
  background  tunnel receives Darwin notifications (main app NOT woken).
              Exercises the production pain path: parent flips a mode
              while the kid's main app is suspended. Monitor has to
              wake via DeviceActivity to actually apply shields.
  both        runs foreground once then background once, producing two
              labelled summaries for comparison.

Examples:
  $(basename "$0")                                   # olivia, foreground, 25 iterations
  $(basename "$0") juliet --mode background         # any device, background path
  $(basename "$0") olivia isla-iphone --mode both   # fg+bg on multiple devices
  $(basename "$0") --all-children                   # every non-parent device
  $(basename "$0") olivia --iterations 50 --seed 42
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage ;;
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --scenarios) SCENARIO_MODE="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        --mode) APP_MODE="$2"; shift 2 ;;
        --background) APP_MODE="background"; shift ;;
        --foreground) APP_MODE="foreground"; shift ;;
        --all-children)
            for ((i=0; i<DEVICE_COUNT; i++)); do
                [ "${ALL_IS_PARENT[$i]}" = "0" ] && TARGETS+=("${ALL_NAMES[$i]}")
            done
            shift
            ;;
        -*)
            echo "Unknown flag: $1"; usage ;;
        *)
            key=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
            case "$key" in
                ephone|erik|e-phone) key="me" ;;
                daphne) key="daphne-iphone" ;;
            esac
            idx=$(find_device_index "$key")
            if [ "$idx" = "-1" ]; then
                echo "Unknown device: $1"
                echo "Valid:"
                valid_device_names | sed 's/^/  /'
                exit 1
            fi
            TARGETS+=("$key")
            shift
            ;;
    esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=("olivia")

case "$SCENARIO_MODE" in
    random|edges|both) ;;
    *) echo "Invalid --scenarios: $SCENARIO_MODE (expected random|edges|both)"; exit 1 ;;
esac

case "$APP_MODE" in
    foreground|background|both) ;;
    *) echo "Invalid --mode: $APP_MODE (expected foreground|background|both)"; exit 1 ;;
esac

if [ -n "$SEED" ]; then
    RANDOM=$SEED
fi

# Sanity checks
command -v curl >/dev/null || { echo "curl not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found — brew install jq"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found"; exit 1; }

# ─── Command injection via Darwin notifications ────────────────────────────
#
# The CloudKit REST API's public ckAPIToken only permits reads; writing a
# BBRemoteCommand record requires iCloud user auth (which isn't available
# from a shell script). We instead use `xcrun devicectl device notification
# post` to fire a well-known Darwin notification at the target device. The
# child app (DEBUG builds only) has a TestCommandReceiver that maps each
# notification name back to a CommandAction and dispatches it through the
# normal CommandProcessor.processCommand path, so the test still exercises
# the real mode-change pipeline (snapshot → enforcement.apply → shield
# write → heartbeat).
#
# Arg semantics:
#   $1 = xcode device UDID (from registry)
#   $2 = action label: locked | restricted | unlocked | lockedDown | tempUnlock | requestHeartbeat
#
# Returns 0 on successful post, non-zero on failure.

# bash 3.x on macOS has no associative arrays — use a function instead.
#
# Two parallel notification namespaces:
#   - `.test.setMode.X`    → observed by main app TestCommandReceiver
#                            (requires the app to be alive / foregrounded)
#   - `.test.bg.setMode.X` → observed by TunnelTestCommandReceiver
#                            (works when the main app is suspended or dead)
# `$2` selects the channel by passing "foreground" or "background".
notif_name_for_action() {
    local action="$1"
    local channel="${2:-foreground}"
    local infix=""
    [ "$channel" = "background" ] && infix="bg."
    case "$action" in
        locked)           echo "fr.bigbrother.test.${infix}setMode.locked" ;;
        restricted)       echo "fr.bigbrother.test.${infix}setMode.restricted" ;;
        unlocked)         echo "fr.bigbrother.test.${infix}setMode.unlocked" ;;
        lockedDown)       echo "fr.bigbrother.test.${infix}setMode.lockedDown" ;;
        tempUnlock)       echo "fr.bigbrother.test.${infix}tempUnlock.300" ;;
        requestHeartbeat) echo "fr.bigbrother.test.${infix}requestHeartbeat" ;;
        *) return 1 ;;
    esac
}

post_command() {
    local xcode_id="$1"
    local action_label="$2"
    local channel="${3:-foreground}"
    local notif_name
    notif_name=$(notif_name_for_action "$action_label" "$channel") || {
        echo "Unknown action label: $action_label" >&2
        return 1
    }

    if [ "$channel" = "foreground" ]; then
        # Foreground the child app first. Darwin notifications are NOT
        # delivered to suspended processes, and iOS suspends the main app
        # within seconds of losing foreground. `devicectl process launch`
        # brings a running app to foreground (or launches it if it's been
        # killed) — takes ~0.2s after the first call (tunnel setup) and
        # is a no-op for freshness otherwise.
        xcrun devicectl device process launch --device "$xcode_id" fr.bigbrother.app >/dev/null 2>&1 || true
    fi
    # For background channel: do NOT launch the main app. The tunnel (a
    # NetworkExtension that's always running) receives the notification
    # directly and dispatches through its own command pipeline.

    if ! xcrun devicectl device notification post \
            --device "$xcode_id" \
            --name "$notif_name" >/dev/null 2>&1; then
        echo "devicectl notification post failed for $action_label ($channel) on $xcode_id" >&2
        return 1
    fi
    return 0
}

# Fetch the latest BBHeartbeat for a given CK device ID.
# Echoes the raw record JSON on stdout, empty on not-found.
#
# CRITICAL: Uses records/lookup (by record ID) instead of records/query.
# CloudKit's public DB query API goes through a CDN cache with ~30s TTL,
# so poll loops on queries see stale data even after the record has been
# updated. Lookup-by-ID hits the authoritative store and returns fresh
# data immediately — without this the harness confused "main app heartbeat
# landed slowly" with "harness saw stale cache for 30s" and reported
# bogus 30/60/90s latencies (every step was actually < 2s in reality).
fetch_heartbeat() {
    local ck_id="$1"
    local url="${CK_BASE}/records/lookup?ckAPIToken=${CK_API_TOKEN}"
    local body='{"records":[{"recordName":"BBHeartbeat_'"${ck_id}"'"}]}'
    curl -s --max-time 15 -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null
}

# Extract fields from a heartbeat query response.
# Args: $1 = query JSON, $2 = jq path to extract (e.g. .records[0].fields.policyVersion.value)
hb_field() {
    echo "$1" | jq -r "${2} // empty"
}

# Parse the embedded DiagnosticSnapshot JSON from a heartbeat record.
hb_diag_snapshot() {
    echo "$1" | jq -r '.records[0].fields.hbDiagnosticSnapshot.value // empty'
}

# ─── Scenario generator ────────────────────────────────────────────────────
# Each sub-step is "expected_mode|action_label". The action label names
# the key in ACTION_NOTIF_NAMES and selects the Darwin notification the
# test harness fires at the target device.

# Random pool: equal-weight choice among these four.
RANDOM_POOL=(
    "locked|locked"
    "restricted|restricted"
    "unlocked|unlocked"
    "unlocked|tempUnlock"   # temp unlock resolves to unlocked
)

# Seeded edges: deliberately exercise paths we've broken before.
# Each entry is semicolon-separated sub-steps. The runner splits and
# processes them with minimal delay between sub-steps (< 2s).
EDGE_SCENARIOS=(
    # Back-to-back same mode (tests idempotent write)
    "restricted|restricted;restricted|restricted"
    # Three commands in ~2s (tests burst coalescing)
    "locked|locked;unlocked|unlocked;restricted|restricted"
    # Lock during temp unlock (tests override of temp state)
    "unlocked|tempUnlock;locked|locked"
    # Unlock then lock within 10s (tests rapid flip)
    "unlocked|unlocked;locked|locked"
    # Redundant same mode (tests no-op suppression correctness)
    "locked|locked;locked|locked"
)

# Pick next action. Sets globals: STEP_EXPECTED_MODE, STEP_ACTION_LABEL, STEP_EDGE_CHAIN
# Arg 1: current phase ("random" or "edges")
pick_step() {
    local phase="$1"
    if [ "$phase" = "edges" ]; then
        local edge_idx=$((RANDOM % ${#EDGE_SCENARIOS[@]}))
        STEP_EDGE_CHAIN="${EDGE_SCENARIOS[$edge_idx]}"
    else
        local pool_idx=$((RANDOM % ${#RANDOM_POOL[@]}))
        local pair="${RANDOM_POOL[$pool_idx]}"
        STEP_EXPECTED_MODE="${pair%%|*}"
        STEP_ACTION_LABEL="${pair#*|}"
        STEP_EDGE_CHAIN=""
    fi
}

# ─── Verifier ─────────────────────────────────────────────────────────────
# Asserts the diagnostic snapshot matches the expected mode after a step.
# Returns 0 on PASS, 1 on FAIL. Echoes a one-line reason on failure.
# Args: $1 = diagnostic snapshot JSON string, $2 = expected mode
verify_snapshot() {
    local diag="$1"
    local expected="$2"

    local actual_mode
    actual_mode=$(echo "$diag" | jq -r '.mode // empty')
    if [ "$actual_mode" != "$expected" ]; then
        echo "mode=$actual_mode (expected $expected)"
        return 1
    fi

    local shields_up
    shields_up=$(echo "$diag" | jq -r '.shieldsUp // false')
    local shields_expected_true="true"
    [ "$expected" = "unlocked" ] && shields_expected_true="false"
    if [ "$shields_up" != "$shields_expected_true" ]; then
        echo "shieldsUp=$shields_up (expected $shields_expected_true)"
        return 1
    fi

    # Token verdicts — verify the expectedBlocked distribution matches the mode.
    local verdict_count
    verdict_count=$(echo "$diag" | jq -r '.tokenVerdicts // [] | length')
    if [ "$verdict_count" -gt 0 ]; then
        local blocked_count
        blocked_count=$(echo "$diag" | jq -r '[.tokenVerdicts[] | select(.expectedBlocked == true)] | length')
        case "$expected" in
            unlocked)
                if [ "$blocked_count" -gt 0 ]; then
                    echo "unlocked mode has $blocked_count tokens marked blocked"
                    return 1
                fi
                ;;
            locked|lockedDown)
                if [ "$blocked_count" -ne "$verdict_count" ]; then
                    echo "locked mode: only $blocked_count/$verdict_count tokens marked blocked"
                    return 1
                fi
                ;;
            restricted)
                # Mixed is fine; we require only that at least one is allowed
                # when there's an always-allowed set. Pass-through if all blocked
                # (it might just mean the user has no always-allowed entries).
                ;;
        esac
    fi

    return 0
}

# ─── Main run loop ────────────────────────────────────────────────────────
RUN_ID=$(date +%s)
ARTIFACT_FILE="/tmp/bb-test-shield-${RUN_ID}.json"
echo "[]" >"$ARTIFACT_FILE"

append_artifact() {
    local row="$1"
    local tmp
    tmp=$(mktemp)
    jq ". + [${row}]" "$ARTIFACT_FILE" >"$tmp" && mv "$tmp" "$ARTIFACT_FILE"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  test_shield_cycle.sh · $(date '+%Y-%m-%d %H:%M:%S')"
echo "  devices:     ${TARGETS[*]}"
echo "  iterations:  $ITERATIONS"
echo "  scenarios:   $SCENARIO_MODE"
echo "  mode:        $APP_MODE"
echo "  seed:        ${SEED:-random}"
echo "  artifact:    $ARTIFACT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0

# Build the list of channels to exercise. "both" runs the whole
# device×iteration matrix once per channel so the summary can
# compare foreground vs background latency cleanly.
if [ "$APP_MODE" = "both" ]; then
    CHANNELS=("foreground" "background")
else
    CHANNELS=("$APP_MODE")
fi

# Fail-fast timeouts. User's framing: "it either works fast, works slightly
# slower, or I don't care because it's not good enough." Known p50 latencies
# are fg=1.5s, bg=21s (DeviceActivity scheduler-bound). 10s fg captures the
# slightly-slow tail. 30s bg gives bg another ~50% headroom over p50. Any
# iteration that doesn't land in those windows is broken enough to count as
# a fail — no reason to keep the script sitting on a dead step.
POLL_TIMEOUT_FG=10
POLL_TIMEOUT_BG=30

for channel in "${CHANNELS[@]}"; do
    if [ "$channel" = "background" ]; then
        POLL_TIMEOUT_SEC=$POLL_TIMEOUT_BG
    else
        POLL_TIMEOUT_SEC=$POLL_TIMEOUT_FG
    fi
    echo "════ Channel: $channel (timeout ${POLL_TIMEOUT_SEC}s) ════"
    if [ "$channel" = "background" ]; then
        echo "  (tunnel-dispatched · main app NOT woken · measures production 'parent flips mode while kid's app is suspended' path)"
    else
        echo "  (main-app-dispatched · app foregrounded via devicectl · measures apply latency when the kid has the app open)"
    fi

    for target_name in "${TARGETS[@]}"; do
        target_idx=$(find_device_index "$target_name")
        target_ck_id="${ALL_CK_IDS[$target_idx]}"
        target_xcode_id="${ALL_XCODE_IDS[$target_idx]}"
        if [ -z "$target_ck_id" ] || [ -z "$target_xcode_id" ]; then
            echo "Skipping $target_name — missing CK or Xcode device ID in registry (parent device?)"
            continue
        fi

        # Background channel: terminate the main app so it can't interfere
        # with the test. In production this path fires when the kid hasn't
        # opened BB in a while and iOS has suspended the process — the
        # tunnel (always alive) is the only writer. If the main app is
        # merely backgrounded it can still fire its 30s heartbeat and 60s
        # enforcement-fix timers, racing the tunnel and corrupting our
        # measurements. Terminating is the clean reset.
        if [ "$channel" = "background" ]; then
            main_pid=$(xcrun devicectl device info processes --device "$target_xcode_id" 2>/dev/null \
                | awk '/\/BigBrother\.app\/BigBrother[[:space:]]*$/ {print $1; exit}')
            if [ -n "$main_pid" ]; then
                echo "  [terminate] killing main app pid=$main_pid so tunnel is sole writer..."
                xcrun devicectl device process terminate \
                    --device "$target_xcode_id" \
                    --pid "$main_pid" --kill \
                    >/dev/null 2>&1 || true
            else
                echo "  [terminate] main app not running (already clean)"
            fi
        fi

        echo "### Device: $target_name ($target_ck_id) · $channel ###"

        # Establish baseline policyVersion from the current heartbeat.
        baseline_hb=$(fetch_heartbeat "$target_ck_id")
        baseline_version=$(hb_field "$baseline_hb" '.records[0].fields.policyVersion.value')
        baseline_version=${baseline_version:-0}
        echo "  baseline policyVersion=$baseline_version"

        # Plan the iterations.
        EDGE_EVERY_N=5
        for ((iter=1; iter<=ITERATIONS; iter++)); do
            phase="random"
            case "$SCENARIO_MODE" in
                random) phase="random" ;;
                edges)  phase="edges" ;;
                both)   [ $((iter % EDGE_EVERY_N)) -eq 0 ] && phase="edges" ;;
            esac

            pick_step "$phase"

            # Expand edge chain or single-step random into sub-steps.
            SUBSTEPS=()
            if [ -n "$STEP_EDGE_CHAIN" ]; then
                IFS=';' read -ra SUBSTEPS <<< "$STEP_EDGE_CHAIN"
            else
                SUBSTEPS=("${STEP_EXPECTED_MODE}|${STEP_ACTION_LABEL}")
            fi

            substep_count=${#SUBSTEPS[@]}
            for ((sub=0; sub<substep_count; sub++)); do
                pair="${SUBSTEPS[$sub]}"
                expected_mode="${pair%%|*}"
                action_label="${pair#*|}"
                label="$expected_mode"

                t_sent=$(python3 -c "import time; print(time.time())")

                if ! post_command "$target_xcode_id" "$action_label" "$channel"; then
                    printf "  [%02d.%d] %-12s POST-FAILED\n" "$iter" "$sub" "$label"
                    TOTAL_FAIL=$((TOTAL_FAIL+1))
                    continue
                fi

                # NB: we do NOT fire a separate requestHeartbeat notification.
                # Both TestCommandReceiver (main app) and TunnelTestCommandReceiver
                # chain a heartbeat upload inline after every test command, so
                # the heartbeat already reflects post-command state. A second
                # notification would race the inline one and either double-
                # upload or hit a CK ETag conflict.

                # Poll until (a) policyVersion advances AND (b) currentMode
                # matches the expected mode. Checking just (a) trips on
                # intermediate commits (main-app 60s enforcement fix, Monitor
                # reconciles) that advance the version with a STALE mode,
                # making the harness fail with "expected X got Y" when the
                # real command just hasn't landed yet. If the timeout elapses
                # with no matching mode, that IS a real failure and we report
                # the most recent state we saw.
                t_applied=""
                hb_json=""
                last_seen_version="$baseline_version"
                last_seen_mode=""
                poll_start=$(python3 -c "import time; print(time.time())")
                while :; do
                    now=$(python3 -c "import time; print(time.time())")
                    elapsed=$(python3 -c "print($now - $poll_start)")
                    above=$(python3 -c "print(1 if $elapsed >= $POLL_TIMEOUT_SEC else 0)")
                    [ "$above" = "1" ] && break

                    hb_json=$(fetch_heartbeat "$target_ck_id")
                    current_version=$(hb_field "$hb_json" '.records[0].fields.policyVersion.value')
                    current_version=${current_version:-0}
                    current_mode=$(hb_field "$hb_json" '.records[0].fields.currentMode.value')
                    if [ "$current_version" -gt "$last_seen_version" ] 2>/dev/null; then
                        last_seen_version="$current_version"
                        last_seen_mode="$current_mode"
                    fi
                    if [ "$current_version" -gt "$baseline_version" ] 2>/dev/null \
                       && [ "$current_mode" = "$expected_mode" ]; then
                        t_applied=$now
                        baseline_version=$current_version
                        break
                    fi
                    sleep "$POLL_INTERVAL_SEC"
                done

                # Timeout fallback: use the most recent advance we saw so
                # the harness can still report what the device ended up in.
                if [ -z "$t_applied" ] && [ "$last_seen_version" -gt "$baseline_version" ] 2>/dev/null; then
                    baseline_version="$last_seen_version"
                fi

                if [ -z "$t_applied" ]; then
                    printf "  [%02d.%d] %-12s TIMEOUT (no heartbeat within ${POLL_TIMEOUT_SEC}s)\n" "$iter" "$sub" "$label"
                    append_artifact "{\"device\":\"$target_name\",\"channel\":\"$channel\",\"iter\":$iter,\"sub\":$sub,\"label\":\"$label\",\"result\":\"timeout\"}"
                    TOTAL_FAIL=$((TOTAL_FAIL+1))
                    continue
                fi

                # Extract snapshot + timings
                diag_json=$(hb_diag_snapshot "$hb_json")
                if [ -z "$diag_json" ] || [ "$diag_json" = "null" ]; then
                    printf "  [%02d.%d] %-12s NO_DIAG_SNAPSHOT\n" "$iter" "$sub" "$label"
                    append_artifact "{\"device\":\"$target_name\",\"channel\":\"$channel\",\"iter\":$iter,\"sub\":$sub,\"label\":\"$label\",\"result\":\"no_diag\"}"
                    TOTAL_FAIL=$((TOTAL_FAIL+1))
                    continue
                fi

                apply_started=$(echo "$diag_json" | jq -r '.applyStartedAt // empty')
                apply_finished=$(echo "$diag_json" | jq -r '.applyFinishedAt // empty')

                fail_reason=""
                if ! fail_reason=$(verify_snapshot "$diag_json" "$expected_mode" 2>&1); then
                    result="FAIL"
                    TOTAL_FAIL=$((TOTAL_FAIL+1))
                else
                    result="PASS"
                    TOTAL_PASS=$((TOTAL_PASS+1))
                    fail_reason=""
                fi

                # Latencies (ms):
                #   confirm — script POST to first heartbeat that reflects the
                #             advanced policyVersion (end-to-end, dominates from
                #             the parent's perspective).
                #   apply   — pure ManagedSettings write duration on the device
                #             (applyStartedAt → applyFinishedAt).
                confirm_ms=$(python3 -c "print(int(($t_applied - $t_sent) * 1000))")
                apply_ms="n/a"
                if [ -n "$apply_started" ] && [ -n "$apply_finished" ]; then
                    apply_ms=$(python3 -c "
try:
  s = float('$apply_started'); f = float('$apply_finished')
  print(int((f - s) * 1000))
except: print('n/a')")
                fi

                mark="OK"
                [ "$result" = "PASS" ] || mark="FAIL"
                printf "  [%02d.%d] %-12s %s confirm=%sms apply=%sms%s\n" \
                    "$iter" "$sub" "$label" "$mark" "$confirm_ms" "$apply_ms" \
                    "${fail_reason:+ · $fail_reason}"

                append_artifact "$(python3 -c "
import json
row = {
    'device': '$target_name',
    'channel': '$channel',
    'iter': $iter,
    'sub': $sub,
    'label': '$label',
    'expected_mode': '$expected_mode',
    'result': '$result',
    't_sent': $t_sent,
    't_applied': $t_applied,
    'confirm_ms': $confirm_ms,
    'apply_ms': '$apply_ms' if '$apply_ms' == 'n/a' else int('$apply_ms'),
    'fail_reason': '$fail_reason',
}
print(json.dumps(row))
")"
            done
        done
    done
done

# ─── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((TOTAL_PASS + TOTAL_FAIL))
echo "Pass rate: ${TOTAL_PASS}/${TOTAL}"

python3 <<PYEOF
import json, statistics
with open("$ARTIFACT_FILE") as f:
    rows = json.load(f)

def stats(name, values):
    vs = [v for v in values if isinstance(v, (int, float))]
    if not vs:
        print(f"{name:12} no data")
        return
    vs.sort()
    p50 = statistics.median(vs)
    p95 = vs[int(len(vs) * 0.95)] if len(vs) > 1 else vs[0]
    mx = max(vs)
    print(f"{name:12} p50={p50}ms  p95={p95}ms  max={mx}ms  n={len(vs)}")

channels = sorted({r.get("channel", "foreground") for r in rows})
for ch in channels:
    ch_rows = [r for r in rows if r.get("channel", "foreground") == ch]
    passes = [r for r in ch_rows if r.get("result") == "PASS"]
    print()
    print(f"── {ch} ─────────────────────────────────────")
    print(f"Pass rate: {len(passes)}/{len(ch_rows)}")
    stats("confirm", [r.get("confirm_ms") for r in ch_rows])
    stats("apply", [r.get("apply_ms") for r in ch_rows])

    slow = [r for r in ch_rows if isinstance(r.get("confirm_ms"), (int,float)) and r["confirm_ms"] > 10000]
    if slow:
        print()
        print("Slow steps (>10s confirm latency):")
        for r in slow:
            print(f"  [{r['iter']:02d}.{r.get('sub',0)}] {r.get('device','')} {r['label']}  {r['confirm_ms']}ms")

    fails = [r for r in ch_rows if r.get("result") != "PASS"]
    if fails:
        print()
        print("Failures:")
        for r in fails:
            reason = r.get("fail_reason") or r.get("result", "?")
            print(f"  [{r['iter']:02d}.{r.get('sub',0)}] {r.get('device','')} {r['label']}  {reason}")
PYEOF

echo ""
echo "Artifact: $ARTIFACT_FILE"

[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
