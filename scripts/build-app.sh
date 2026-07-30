#!/bin/bash
# Ensambla SwitchBar.app a partir del binario de SwiftPM y lo firma.
# Uso: scripts/build-app.sh [identidad-de-firma]
#   - Sin argumento: prefiere Developer ID Application y después la identidad
#     local "SwitchBar Self-Signed".
#
# Una firma estable es obligatoria: el Llavero asocia el almacén privado de
# perfiles a la identidad de código. Una firma ad-hoc distinta en cada build
# volvería a pedir autorización tras actualizar la app.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/SwitchBar.app"

# Se usa la huella SHA-1 para evitar ambigüedad si hay nombres duplicados.
SIGN_ID="${1:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -p codesigning -v 2>/dev/null \
        | awk '/Developer ID Application/ {print $2; exit}')"
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -p codesigning -v 2>/dev/null \
        | awk '/SwitchBar Self-Signed|ClaudeSwitch Self-Signed/ {print $2; exit}')"
fi
if [ -z "$SIGN_ID" ]; then
    if [ "${SWITCHBAR_ALLOW_ADHOC:-0}" = "1" ]; then
        SIGN_ID="-"
        echo "AVISO: firma ad-hoc; no la uses para una instalación persistente."
    else
        echo "ERROR: no hay una identidad de firma estable disponible." >&2
        echo "Instala un certificado Developer ID o SwitchBar Self-Signed." >&2
        echo "Solo para desarrollo efímero: SWITCHBAR_ALLOW_ADHOC=1 make app" >&2
        exit 1
    fi
fi

# Binario universal: macOS Tahoe también corre en los últimos Mac Intel.
ARCHS=(--arch arm64 --arch x86_64)
echo "==> Compilando en release (universal: arm64 + x86_64)…"
swift build -c release "${ARCHS[@]}"

BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path 2>/dev/null)"
BIN="$BIN_DIR/SwitchBar"

echo "==> Ensamblando ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SwitchBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for language in es en fr de pt-BR it ja ko zh-Hans zh-Hant; do
    cp -R \
        "$ROOT/Sources/SwitchBarCore/Resources/$language.lproj" \
        "$APP/Contents/Resources/$language.lproj"
done
# `swift run` usa este bundle; se conserva también en la app para que las
# traducciones estén disponibles con cualquier forma de ejecución.
find "$BIN_DIR" -maxdepth 1 -type d -name '*SwitchBarCore*.bundle' \
    -exec cp -R {} "$APP/Contents/Resources/" \;

echo "==> Firmando con identidad: $SIGN_ID"
# Hardened runtime y marca temporal segura: requisitos de la notarización.
# Con firma ad-hoc no hay marca temporal (Apple no la emite para "-").
TIMESTAMP_FLAG="--timestamp"
[ "$SIGN_ID" = "-" ] && TIMESTAMP_FLAG=""
# El identificador de firma NO debe cambiarse: el Llavero guarda el requisito
# designado de la app que creó la entrada privada de perfiles. Firmar con otro
# identificador convierte a SwitchBar en «otra aplicación» y macOS pide la
# contraseña del Llavero en cada acceso. Se conserva el histórico.
codesign --force --options runtime $TIMESTAMP_FLAG \
    --identifier com.mlopara.ClaudeSwitch --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Listo: $APP"
