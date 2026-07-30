#!/bin/bash
# Empaqueta SwitchBar.app en un DMG de distribución y publica su SHA-256.
# Uso: scripts/make-dmg.sh [version]
#   - version: sufijo del nombre del archivo (p. ej. 1.0.0-beta.1).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/SwitchBar.app"
VERSION="${1:-dev}"
DMG="$ROOT/SwitchBar-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

if [ ! -d "$APP" ]; then
    echo "ERROR: no existe $APP; ejecuta antes 'make app'." >&2
    exit 1
fi

cp -R "$APP" "$STAGING/SwitchBar.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "SwitchBar" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null

echo "==> DMG: $DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
