#!/bin/bash
# build.sh — compile TranslateMate.app, không cần mở Xcode.
# Yêu cầu: xcode-select --install
#
# Dùng:
#   ./build.sh                -> build .app vào ./build/
#   ./build.sh run            -> build và mở app luôn
#   ./build.sh dmg            -> build và đóng gói DMG
#   ./build.sh install        -> build và copy vào /Applications/ (workflow ổn định)
#   ./build.sh setup-cert     -> tạo self-signed cert một lần (giữ Accessibility grant)
#   ./build.sh reset-tcc      -> xoá entry Accessibility cũ để re-grant clean
#
set -euo pipefail

# ---------- Config ----------
APP_NAME="TranslateMate"
BUNDLE_ID="com.tuanduong.translatemate"
VERSION="1.0"
BUILD="1"
MIN_MACOS="13.0"

# Tên cert local. Một lần tạo, dùng mãi → cdhash binding qua cert identity, không phải content hash.
CERT_NAME="TranslateMate Local Dev"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/TranslateMate"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

CMD="${1:-}"

# ===========================================================================
# Sub-command: setup-cert
# Tạo một code-signing cert tự ký, lưu vào login keychain. Dùng cho mọi lần
# build sau này → cdhash sẽ stable theo cert identity, Accessibility grant sống
# qua mọi rebuild.
# ===========================================================================
if [[ "$CMD" == "setup-cert" ]]; then
    if security find-certificate -c "$CERT_NAME" -a >/dev/null 2>&1 && \
       security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
        echo "✅  Cert '$CERT_NAME' đã tồn tại. Không cần tạo lại."
        exit 0
    fi

    echo "🔧  Tạo self-signed code-signing certificate '$CERT_NAME'…"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    # OpenSSL v3 trở lên có sẵn trên macOS.
    cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_req
[req_distinguished_name]
CN = $CERT_NAME
[v3_req]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 -nodes -config "$TMP/cert.cnf" >/dev/null 2>&1

    # Convert sang PKCS12 (.p12) để import được vào keychain
    openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/cert.p12" -name "$CERT_NAME" -passout pass: >/dev/null

    # Import vào login keychain
    LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    [[ -f "$LOGIN_KEYCHAIN" ]] || LOGIN_KEYCHAIN="$(security default-keychain -d user | tr -d '"' | xargs)"

    security import "$TMP/cert.p12" -k "$LOGIN_KEYCHAIN" -P "" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s -k "" \
        "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true

    # Mark cert as trusted for code signing
    security add-trusted-cert -d -r trustRoot -k "$LOGIN_KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || \
    security add-trusted-cert -p codeSign -k "$LOGIN_KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || true

    echo ""
    echo "✅  Cert '$CERT_NAME' đã được tạo và import vào login keychain."
    echo ""
    echo "📌  Bước tiếp theo:"
    echo "    1. Build lại: ./build.sh run"
    echo "    2. Khi macOS hỏi quyền Accessibility, grant 1 lần"
    echo "    3. Từ giờ rebuild bao nhiêu lần cũng không phải re-grant nữa"
    echo ""
    exit 0
fi

# ===========================================================================
# Sub-command: reset-tcc
# Xoá entry Accessibility hiện tại của app. Lần chạy tiếp theo macOS sẽ hỏi
# fresh permission. Dùng khi grant cũ bị invalidate vì cdhash đổi.
# ===========================================================================
if [[ "$CMD" == "reset-tcc" ]]; then
    echo "🧹  Resetting TCC (Accessibility) entry cho $BUNDLE_ID…"
    # Quit app trước
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    pkill -f "$APP_NAME" 2>/dev/null || true
    sleep 0.5

    tccutil reset Accessibility "$BUNDLE_ID" 2>&1 || \
        echo "(tccutil không có entry để reset, OK)"

    echo "✅  Done. Mở app bằng: ./build.sh run — macOS sẽ hỏi grant lại."
    exit 0
fi

# ===========================================================================
# Build chính
# ===========================================================================

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "❌  swiftc không có sẵn. Chạy: xcode-select --install"
    exit 1
fi

ARCH="$(uname -m)"
echo "🔨  Building $APP_NAME ($ARCH, min macOS $MIN_MACOS)…"

# Quit running instance để tránh "file in use" khi ghi đè binary
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
pkill -f "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.3

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

SOURCES=(
    "$SRC_DIR/TranslateMateApp.swift"
    "$SRC_DIR/AppDelegate.swift"
    "$SRC_DIR/HotkeyShortcut.swift"
    "$SRC_DIR/HotkeyManager.swift"
    "$SRC_DIR/HotkeyRecorderView.swift"
    "$SRC_DIR/TextBridge.swift"
    "$SRC_DIR/OpenRouterClient.swift"
    "$SRC_DIR/SettingsStore.swift"
    "$SRC_DIR/SettingsView.swift"
    "$SRC_DIR/Keychain.swift"
    "$SRC_DIR/Logger.swift"
    "$SRC_DIR/TranslationPopup.swift"
    "$SRC_DIR/RateLimitTracker.swift"
)
for f in "${SOURCES[@]}"; do
    [[ -f "$f" ]] || { echo "❌  Thiếu file: $f"; exit 1; }
done

TARGET="${ARCH}-apple-macos${MIN_MACOS}"
xcrun swiftc \
    -target "$TARGET" \
    -O \
    -module-name "$APP_NAME" \
    -emit-executable \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework Security \
    "${SOURCES[@]}"

echo "✅  Compiled $MACOS_DIR/$APP_NAME"

if [[ -f "$SCRIPT_DIR/assets/AppIcon.icns" ]]; then
    cp "$SCRIPT_DIR/assets/AppIcon.icns" "$RES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>TranslateMate uses Apple Events to paste translated text back into the focused app.</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$CONTENTS/PkgInfo"

# ---------- Sign ----------
# Ưu tiên cert tự ký (stable cdhash binding), fallback ad-hoc.
SIGN_IDENTITY="-"
SIGN_LABEL="ad-hoc"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    SIGN_IDENTITY="$CERT_NAME"
    SIGN_LABEL="self-signed cert ($CERT_NAME)"
fi

codesign --force --deep --sign "$SIGN_IDENTITY" \
    --entitlements /dev/stdin \
    "$APP_BUNDLE" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
</dict>
</plist>
ENT

xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
echo "✅  Signed ($SIGN_LABEL): $APP_BUNDLE"

if [[ "$SIGN_LABEL" == "ad-hoc" ]]; then
    echo ""
    echo "💡  Tip: chạy './build.sh setup-cert' MỘT LẦN để tránh phải re-grant Accessibility mỗi lần rebuild."
    echo ""
fi

# ---------- DMG ----------
if [[ "$CMD" == "dmg" ]]; then
    DMG_FINAL="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
    STAGE_DIR="$BUILD_DIR/stage"
    rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"
    cp -R "$APP_BUNDLE" "$STAGE_DIR/"
    ln -s /Applications "$STAGE_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_FINAL" >/dev/null
    echo "📦  DMG: $DMG_FINAL"
fi

# ---------- Install vào /Applications ----------
if [[ "$CMD" == "install" ]]; then
    echo "📥  Installing vào /Applications/…"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP_BUNDLE" /Applications/
    echo "✅  Installed: /Applications/${APP_NAME}.app"
    echo "   Mở từ Spotlight, /Applications, hoặc:"
    echo "   open /Applications/${APP_NAME}.app"
fi

# ---------- Run ----------
if [[ "$CMD" == "run" ]]; then
    echo "🚀  Launching…"
    open "$APP_BUNDLE"
fi

echo ""
echo "✨  Xong. Mở app bằng: open \"$APP_BUNDLE\""
