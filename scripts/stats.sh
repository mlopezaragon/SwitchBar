#!/bin/bash
# Muestra cuánta gente descarga SwitchBar: el DMG publicado en GitHub
# Releases y el uso del tap de Homebrew.
# Uso: scripts/stats.sh
#
# Requiere la CLI de GitHub autenticada ('gh auth login'): las cifras de
# tráfico del tap y del repositorio solo se sirven a quien tiene acceso de
# escritura. Las descargas del DMG son públicas y no necesitan credenciales.
#
# GitHub solo conserva 14 días de tráfico, así que cada ejecución añade una
# línea a .stats/history.csv (fuera del control de versiones) para poder ver
# la evolución más allá de esa ventana.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="mlopezaragon/SwitchBar"
TAP="mlopezaragon/homebrew-tap"
HISTORIAL=".stats/history.csv"

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: falta la CLI de GitHub; instálala con 'brew install gh'." >&2
    exit 1
fi

# --- Descargas del DMG ------------------------------------------------------
# Una línea por versión: etiqueta, descargas sumadas de sus DMG y fecha de
# publicación. Los .sha256 se ignoran: interesa quién se lleva la app.
DESCARGAS="$(gh api "repos/$REPO/releases" --paginate --jq \
    '.[] | [.tag_name,
            ([.assets[] | select(.name | endswith(".dmg")) | .download_count] | add // 0),
            (.published_at | split("T")[0])] | @tsv')"

TOTAL="$(printf '%s\n' "$DESCARGAS" | awk -F'\t' '{s += $2} END {print s + 0}')"

echo "==> Descargas del DMG (GitHub Releases)"
echo
printf '    %-22s %8s   %s\n' "versión" "descargas" "publicada"
printf '%s\n' "$DESCARGAS" | awk -F'\t' '{printf "    %-22s %8d   %s\n", $1, $2, $3}'
printf '    %-22s %8d\n' "TOTAL" "$TOTAL"
echo
echo "    Incluye las tres vías, que comparten el mismo fichero: descarga"
echo "    directa desde la web o el repositorio, instalación con Homebrew y"
echo "    actualización automática de Sparkle."

# --- Homebrew ---------------------------------------------------------------
# El tap es propio, así que Homebrew no publica sus analytics oficiales (solo
# cubren homebrew/core y homebrew/cask). La señal disponible es cuánta gente
# clona el repositorio del tap, que es lo que hace 'brew install' la primera
# vez que alguien usa el tap.
echo
echo "==> Homebrew (tap $TAP)"
echo
if CLONES="$(gh api "repos/$TAP/traffic/clones" --jq '[.count, .uniques] | @tsv' 2>/dev/null)"; then
    printf '%s\n' "$CLONES" | awk -F'\t' '{
        printf "    Clones del tap, últimos 14 días: %d (%d equipos distintos)\n", $1, $2
    }'
    echo
    echo "    Aproxima cuánta gente instala con 'brew install --cask"
    echo "    mlopezaragon/tap/switchbar' por primera vez. Un tap propio no"
    echo "    aparece en las analíticas oficiales de Homebrew; para eso el"
    echo "    cask tendría que entrar en homebrew-cask."
else
    echo "    Sin datos: la API de tráfico exige acceso de escritura al tap."
    echo "    Revisa 'gh auth status' y que la cuenta sea la dueña del tap."
fi

# --- Interés en el repositorio ---------------------------------------------
echo
echo "==> Repositorio $REPO"
echo
if VISTAS="$(gh api "repos/$REPO/traffic/views" --jq '[.count, .uniques] | @tsv' 2>/dev/null)"; then
    printf '%s\n' "$VISTAS" | awk -F'\t' '{
        printf "    Visitas, últimos 14 días: %d (%d personas distintas)\n", $1, $2
    }'
else
    VISTAS=$'0\t0'
    echo "    Sin datos de tráfico."
fi
ESTRELLAS="$(gh api "repos/$REPO" --jq '.stargazers_count')"
printf '    Estrellas: %s\n' "$ESTRELLAS"

# --- Historial --------------------------------------------------------------
# Una línea por ejecución, para conservar lo que GitHub borra a los 14 días.
mkdir -p .stats
if [ ! -f "$HISTORIAL" ]; then
    echo "fecha,descargas_dmg,clones_tap,equipos_tap,visitas_repo,personas_repo,estrellas" > "$HISTORIAL"
fi
CLONES="${CLONES:-$'0\t0'}"
printf '%s,%s,%s,%s,%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$TOTAL" \
    "$(printf '%s' "$CLONES" | tr '\t' ',')" \
    "$(printf '%s' "$VISTAS" | tr '\t' ',')" \
    "$ESTRELLAS" >> "$HISTORIAL"

REGISTROS=$(($(wc -l < "$HISTORIAL") - 1))
echo
if [ "$REGISTROS" -eq 1 ]; then
    echo "    Instantánea guardada en $HISTORIAL (1 registro)."
else
    echo "    Instantánea guardada en $HISTORIAL ($REGISTROS registros)."
fi
