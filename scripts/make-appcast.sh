#!/bin/bash
# Regenera appcast.xml (el canal de actualizaciones de Sparkle) para un DMG.
# Uso: scripts/make-appcast.sh <version>
#
# Firma el DMG con la clave EdDSA privada guardada en el Llavero (creada con
# generate_keys) y publica un único item: la última versión disponible. El
# feed se sirve desde el propio repositorio (rama main, vía raw).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?Uso: scripts/make-appcast.sh <version>}"
DMG="SwitchBar-$VERSION.dmg"
if [ ! -f "$DMG" ]; then
    echo "ERROR: falta $DMG; ejecuta antes 'make dmg'." >&2
    exit 1
fi

SIGN_UPDATE="$(find .build/artifacts -name sign_update -type f 2>/dev/null | head -1)"
if [ -z "$SIGN_UPDATE" ]; then
    echo "ERROR: no se encontró sign_update; ejecuta 'swift build' primero." >&2
    exit 1
fi

# Devuelve exactamente los atributos del enclosure:
#   sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN_UPDATE" "$DMG")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
URL="https://github.com/mlopezaragon/SwitchBar/releases/download/v$VERSION/$DMG"
DATE="$(LC_ALL=en_US.UTF-8 date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SwitchBar</title>
    <link>https://github.com/mlopezaragon/SwitchBar</link>
    <item>
      <title>SwitchBar $SHORT</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/mlopezaragon/SwitchBar/releases/tag/v$VERSION</link>
      <enclosure url="$URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

echo "==> appcast.xml regenerado: $SHORT (build $BUILD) -> $URL"
echo "    Recuerda hacer commit y push de appcast.xml: el feed vive en main."
