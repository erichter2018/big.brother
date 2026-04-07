#!/bin/bash
set -e

SCHEME="BigBrother"
PROJECT="BigBrother.xcodeproj"
ARCHIVE="/tmp/BigBrother.xcarchive"
EXPORT="/tmp/BigBrotherExport"
PLIST="/tmp/ExportOptions.plist"

API_KEY="74AAPQBWP9"
API_ISSUER="5e4d4222-7573-42c9-96e7-fb8ed03550b8"
API_KEY_PATH="$HOME/.private_keys/AuthKey_${API_KEY}.p8"

echo "=== Step 1: Archive ==="
rm -rf "$ARCHIVE"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  archive -allowProvisioningUpdates \
  | tail -3

echo ""
echo "=== Step 2: Export IPA ==="
rm -rf "$EXPORT"

cat > "$PLIST" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>CN27Z34P76</string>
    <key>uploadSymbols</key>
    <false/>
</dict>
</plist>
EOF

# Export the IPA locally (no upload yet)
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$PLIST" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$API_KEY_PATH" \
  -authenticationKeyID "$API_KEY" \
  -authenticationKeyIssuerID "$API_ISSUER" \
  | tail -5

echo ""
echo "=== Step 3: Upload to App Store Connect ==="
xcrun altool --upload-app \
  -f "$EXPORT/BigBrother.ipa" \
  -t ios \
  --apiKey "$API_KEY" \
  --apiIssuer "$API_ISSUER" \
  2>&1 | tail -10

echo ""
echo "=== Done! Check App Store Connect for processing status ==="
