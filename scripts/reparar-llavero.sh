#!/bin/bash
# Reconstruye la entrada "Claude Code-credentials" del Llavero con una lista de
# accesos permisiva (-A), para que ni Claude Code ni ClaudeSwitch vuelvan a
# pedir la contraseña del Llavero en cada acceso.
#
# Por qué hace falta: al escribir esa entrada con la API SecItem, macOS ató su
# autorización a la firma de la app que la escribió y dejó fuera a
# /usr/bin/security, que es el programa con el que Claude Code lee y escribe su
# sesión. Actualizar la entrada no repara esa lista; hay que recrearla.
#
# La contraseña del Llavero se pide UNA vez, al leer el valor actual.
set -euo pipefail

SERVICE="Claude Code-credentials"
ACCOUNT="$(id -un)"
BACKUP="$HOME/.claude-credentials-backup-$(date +%Y%m%d-%H%M%S).json"

echo "==> Leyendo la sesión actual de Claude Code (pedirá la contraseña una vez)…"
VALUE="$(/usr/bin/security find-generic-password -s "$SERVICE" -w)"

if ! printf '%s' "$VALUE" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'claudeAiOauth' in d" 2>/dev/null; then
    echo "ERROR: el contenido leído no es una sesión válida. No se toca nada." >&2
    exit 1
fi

printf '%s' "$VALUE" > "$BACKUP"
chmod 600 "$BACKUP"
echo "==> Copia de seguridad en $BACKUP"

echo "==> Recreando la entrada con acceso permanente…"
/usr/bin/security delete-generic-password -s "$SERVICE" >/dev/null 2>&1 || true
/usr/bin/security add-generic-password -U -A -s "$SERVICE" -a "$ACCOUNT" -w "$VALUE"

echo "==> Comprobando que ya se lee sin pedir nada…"
CHECK="$(/usr/bin/security find-generic-password -s "$SERVICE" -w)"
if [ "$CHECK" = "$VALUE" ]; then
    echo "LISTO: la sesión está intacta y el acceso ya no pedirá contraseña."
    echo "Si todo va bien, puedes borrar la copia: rm $BACKUP"
else
    echo "ERROR: la verificación no coincide. Restaura con:" >&2
    echo "  /usr/bin/security add-generic-password -U -A -s '$SERVICE' -a '$ACCOUNT' -w \"\$(cat $BACKUP)\"" >&2
    exit 1
fi
