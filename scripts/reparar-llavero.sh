#!/bin/bash
# Diagnóstico conservador del Llavero para Claude Code y SwitchBar.
#
# Este script nunca lee, exporta, borra ni recrea "Claude Code-credentials".
# Tampoco usa `-A` (acceso para cualquier app) ni guarda tokens en ficheros.
set -euo pipefail

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TEST_SERVICE="SwitchBar-selftest"
TEST_ACCOUNT="$(id -un)"

echo "==> Comprobando que el Llavero login admite escritura…"
security add-generic-password \
    -U \
    -a "$TEST_ACCOUNT" \
    -s "$TEST_SERVICE" \
    -w "escritura-ok" \
    "$LOGIN_KEYCHAIN" >/dev/null
security delete-generic-password \
    -a "$TEST_ACCOUNT" \
    -s "$TEST_SERVICE" \
    "$LOGIN_KEYCHAIN" >/dev/null
echo "OK: escritura y borrado funcionan."

echo "==> Estado oficial de Claude Code…"
claude auth status --text

echo "==> Diagnóstico oficial…"
claude doctor

echo
echo "No se ha modificado ninguna sesión."
echo "Si Claude Code no figura conectado, ejecuta:"
echo "  claude auth login --claudeai"
