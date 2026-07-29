#!/bin/bash
# Ensambla ClaudeSwitch.app a partir del binario de SwiftPM y lo firma.
# Uso: scripts/build-app.sh [identidad-de-firma]
#   - Sin argumento: usa "ClaudeSwitch Self-Signed" si existe; si no, firma ad-hoc (-).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/ClaudeSwitch.app"

# Identidad de firma. Se prefiere la huella SHA-1 del certificado local
# "ClaudeSwitch Self-Signed": el nombre puede aparecer duplicado en el llavero
# y codesign fallaría por ambigüedad. Sin certificado, firma ad-hoc (-).
SIGN_ID="${1:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -p codesigning -v 2>/dev/null \
        | awk '/ClaudeSwitch Self-Signed/ {print $2; exit}')"
    [ -z "$SIGN_ID" ] && SIGN_ID="-"
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
