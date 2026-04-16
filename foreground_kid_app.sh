#!/usr/bin/env bash
# Launch Big.Brother on a kid device to bring it to the foreground.
# Pairs with background_kid_app.sh for testing FG vs BG shield latency.
#
# Usage:
#   ./foreground_kid_app.sh juliet

set -o pipefail

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

NAME="$1"
[ -z "$NAME" ] && { echo "Usage: $0 <device-name>"; exit 1; }
XID=$(lookup "$NAME")
[ -z "$XID" ] && { echo "Unknown device: $NAME"; exit 1; }

echo "Foregrounding fr.bigbrother.app on $NAME ($XID)..."
xcrun devicectl device process launch --device "$XID" fr.bigbrother.app
echo "Done. Big.Brother should now be foregrounded on $NAME."
