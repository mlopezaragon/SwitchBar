#!/bin/bash
# Ensambla ClaudeSwitch.app a partir del binario de SwiftPM y lo firma.
# Uso: scripts/build-app.sh [identidad-de-firma]
#   - Sin argumento: usa "ClaudeSwitch Self-Signed" si existe; si no, firma ad-hoc (-).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/ClaudeSwitch.app"

SIGN_ID="${1:-}"
if [ -z "$SIGN_ID" ]; then
    if security find-identity -p codesigning | grep -q "ClaudeSwitch Self-Signed"; then
        SIGN_ID="ClaudeSwitch Self-Signed"
    else
        SIGN_ID="-"
    fi
fi

echo "==> Compilando en release (arm64)…"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path 2>/dev/null)/ClaudeSwitch"

echo "==> Ensamblando ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSwitch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Firmando con identidad: $SIGN_ID"
codesign --force --options runtime --identifier com.mlopara.ClaudeSwitch --sign "$SIGN_ID" "$APP"

echo "==> Listo: $APP"
