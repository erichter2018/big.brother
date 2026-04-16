#!/usr/bin/env bash
# One-shot smoke test: prove the server-to-server key + signing works.
# Does a harmless records/lookup for a dummy record name. Expected: server
# returns 200 OK with a NOT_FOUND for the record (which means auth passed).
# If auth is broken, we get a 401 or AUTHENTICATION_FAILED.

set -o pipefail

CK_CONTAINER="iCloud.fr.bigbrother.app"
CK_ENV="development"
CK_HOST="https://api.apple-cloudkit.com"
CK_SUBPATH_PREFIX="/database/1/${CK_CONTAINER}/${CK_ENV}/public"

CK_SERVER_KEY_ID="${CK_SERVER_KEY_ID:-42d7679baf2719d6f53559070d022dc5af6b55f6f11a4b28077d459c2b5faa0e}"
CK_SERVER_KEY_PEM="${CK_SERVER_KEY_PEM:-$HOME/eckey.pem}"

[ -f "$CK_SERVER_KEY_PEM" ] || { echo "PEM not found at $CK_SERVER_KEY_PEM"; exit 1; }

subpath="${CK_SUBPATH_PREFIX}/records/lookup"
body='{"records":[{"recordName":"__smoke_test_does_not_exist__"}]}'

body_file=$(mktemp)
printf '%s' "$body" > "$body_file"

body_hash=$(openssl dgst -sha256 -binary < "$body_file" | openssl base64 -A)
date_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sig_input="${date_iso}:${body_hash}:${subpath}"
signature=$(printf '%s' "$sig_input" | openssl dgst -sha256 -sign "$CK_SERVER_KEY_PEM" | openssl base64 -A)

echo "KeyID:     $CK_SERVER_KEY_ID"
echo "Date:      $date_iso"
echo "Subpath:   $subpath"
echo "SigInput:  $sig_input"
echo "---"

http_code=$(curl -s -o /tmp/ck_s2s_smoke.json -w "%{http_code}" -X POST "${CK_HOST}${subpath}" \
    -H "Content-Type: application/json" \
    -H "X-Apple-CloudKit-Request-KeyID: ${CK_SERVER_KEY_ID}" \
    -H "X-Apple-CloudKit-Request-ISO8601Date: ${date_iso}" \
    -H "X-Apple-CloudKit-Request-SignatureV1: ${signature}" \
    --data-binary @"$body_file")

rm -f "$body_file"

echo "HTTP:      $http_code"
echo "Response:"
cat /tmp/ck_s2s_smoke.json | python3 -m json.tool 2>/dev/null || cat /tmp/ck_s2s_smoke.json
echo ""

if [ "$http_code" = "200" ]; then
    # NOT_FOUND for the dummy record means auth succeeded
    err=$(python3 -c "import json,sys; d=json.load(open('/tmp/ck_s2s_smoke.json')); print(d.get('records',[{}])[0].get('serverErrorCode',''))" 2>/dev/null)
    if [ "$err" = "NOT_FOUND" ] || [ "$err" = "" ]; then
        echo "AUTH OK -- server accepted the signature."
        exit 0
    fi
fi

echo "AUTH FAILED -- signature or key rejected."
exit 1
