#!/usr/bin/env bash
# Background Big.Brother on a kid device by launching Settings (or any
# foreground-friendly system app). Used to measure command delivery in the
# "main app backgrounded" scenario (tunnel-polling path).
#
# Usage:
#   ./background_kid_app.sh juliet
#   ./background_kid_app.sh juliet --app com.apple.mobilesafari
#
# Why Settings: always installed, always launchable, doesn't change device
# state. Apps that require network or user interaction would interfere.

set -o pipefail

# Device registry (subset from deploy_everywhere.sh)
declare -a NAMES XIDS
add() { NAMES+=("$1"); XIDS+=("$2"); }
add "juliet"        "3B6FC561-C28A-5F20-8232-E8058A24DDCE"
add "isla-iphone"   "DB7F2BA3-46E4-59D1-9BE1-60EAB324F183"
add "isla-ipad"     "35427EB0-3804-50B7-A069-970F7307D977"
add "sebastian"     "C17B60F1-467D-5EC5-BA70-783D19C91249"
add "simon"         "66E78D1B-93D0-5D58-8505-DCF40709942F"
add "olivia"        "A3A7322E-9740-5388-9B4C-E99B7537F2E6"
add "olivia-ipad"   "DF8EDC8C-4FF8-510D-A835-ABE3754CA764"
add "daphne-iphone" "39B6646E-F780-572D-AC85-9CB24851A113"
add "daphne-ipad"   "875F45A5-CA62-515B-8C70-116B06D8021F"

lookup() {
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [ "${NAMES[$i]}" = "$1" ] && echo "${XIDS[$i]}" && return 0
    done
    return 1
}

NAME=""
APP="com.apple.Preferences"

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        *)     NAME="$1"; shift ;;
    esac
done

[ -z "$NAME" ] && { echo "Usage: $0 <device-name> [--app <bundle-id>]"; exit 1; }
XID=$(lookup "$NAME")
[ -z "$XID" ] && { echo "Unknown device: $NAME"; exit 1; }

echo "Launching $APP on $NAME ($XID) to background Big.Brother..."
xcrun devicectl device process launch --device "$XID" "$APP"
echo "Done. Big.Brother should now be backgrounded on $NAME."
