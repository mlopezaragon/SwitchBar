#!/bin/bash
# Notariza un DMG de SwitchBar y adjunta el ticket (staple).
# Uso: scripts/notarize.sh SwitchBar-<version>.dmg
#
# Requiere haber guardado una vez las credenciales de App Store Connect:
#   xcrun notarytool store-credentials switchbar-notary \
#       --apple-id <tu-apple-id> --team-id <TEAM_ID> \
#       --password <contraseña-de-app>
# La contraseña de app se crea en https://account.apple.com (no es la
# contraseña normal del Apple ID).
set -euo pipefail

DMG="${1:?Uso: scripts/notarize.sh SwitchBar-<version>.dmg}"
PROFILE="${SWITCHBAR_NOTARY_PROFILE:-switchbar-notary}"

echo "==> Enviando a notarización (perfil: $PROFILE)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Adjuntando el ticket al DMG…"
xcrun stapler staple "$DMG"

echo "==> Verificación final:"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "==> Regenera el SHA-256 (el staple modifica el archivo):"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
