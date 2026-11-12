#!/bin/zsh
# Builds PadPal.app in this folder.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=PadPal.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PadPal "$APP/Contents/MacOS/PadPal"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.padpal.app</string>
    <key>CFBundleName</key><string>PadPal</string>
    <key>CFBundleExecutable</key><string>PadPal</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
mkdir -p "$APP/Contents/Resources"
cp design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a fixed local identity so macOS keeps the app's permissions across rebuilds.
# The identity lives in its own keychain file; your login keychain is not touched.
KC="$HOME/Library/Application Support/PadPal/signing.keychain-db"
NAME="PadPal Local Signing"
PW=padpal
if [ ! -f "$KC" ]; then
    TMP=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
        -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
        -passout pass:$PW -out "$TMP/id.p12" 2>/dev/null \
      || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
        -passout pass:$PW -out "$TMP/id.p12"
    mkdir -p "$(dirname "$KC")"
    security create-keychain -p $PW "$KC"
    security set-keychain-settings "$KC"
    security unlock-keychain -p $PW "$KC"
    security import "$TMP/id.p12" -k "$KC" -P $PW -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PW "$KC" >/dev/null
    rm -rf "$TMP"
fi
security unlock-keychain -p $PW "$KC"
HASH=$(security find-certificate -c "$NAME" -Z "$KC" | awk '/SHA-1/ {print $NF}')
if ! codesign --force --keychain "$KC" --sign "$HASH" "$APP"; then
    echo "Local signing failed; falling back to ad-hoc (permissions will reset on each build)."
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
