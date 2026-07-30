#!/bin/bash
# Ensambla ClaudeSwitch.app a partir del binario de SwiftPM y lo firma.
# Uso: scripts/build-app.sh [identidad-de-firma]
#   - Sin argumento: prefiere Developer ID Application y después la identidad
#     local "ClaudeSwitch Self-Signed".
#
# Una firma estable es obligatoria: el Llavero asocia el almacén privado de
# perfiles a la identidad de código. Una firma ad-hoc distinta en cada build
# volvería a pedir autorización tras actualizar la app.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/ClaudeSwitch.app"

# Se usa la huella SHA-1 para evitar ambigüedad si hay nombres duplicados.
SIGN_ID="${1:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -p codesigning -v 2>/dev/null \
        | awk '/Developer ID Application/ {print $2; exit}')"
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -p codesigning -v 2>/dev/null \
        | awk '/ClaudeSwitch Self-Signed/ {print $2; exit}')"
fi
if [ -z "$SIGN_ID" ]; then
    if [ "${CLAUDESWITCH_ALLOW_ADHOC:-0}" = "1" ]; then
        SIGN_ID="-"
        echo "AVISO: firma ad-hoc; no la uses para una instalación persistente."
    else
        echo "ERROR: no hay una identidad de firma estable disponible." >&2
        echo "Instala un certificado Developer ID o ClaudeSwitch Self-Signed." >&2
        echo "Solo para desarrollo efímero: CLAUDESWITCH_ALLOW_ADHOC=1 make app" >&2
        exit 1
    fi
fi

echo "==> Compilando en release (arm64)…"
swift build -c release --arch arm64

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path 2>/dev/null)"
BIN="$BIN_DIR/ClaudeSwitch"

echo "==> Ensamblando ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSwitch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for language in es en fr de pt-BR it ja ko zh-Hans zh-Hant; do
    cp -R \
        "$ROOT/Sources/ClaudeSwitchCore/Resources/$language.lproj" \
        "$APP/Contents/Resources/$language.lproj"
done
# `swift run` usa este bundle; se conserva también en la app para que las
# traducciones estén disponibles con cualquier forma de ejecución.
find "$BIN_DIR" -maxdepth 1 -type d -name '*ClaudeSwitchCore*.bundle' \
    -exec cp -R {} "$APP/Contents/Resources/" \;

echo "==> Firmando con identidad: $SIGN_ID"
codesign --force --options runtime --identifier com.mlopara.ClaudeSwitch --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Listo: $APP"
