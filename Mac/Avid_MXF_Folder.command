#!/bin/bash
# Avid_MXF_Folder.command  —  versión Mac de Avid_MXF_Folder.bat
# Doble clic: pide que arrastres el bin (.avb) a la ventana.
# Desde la Terminal también acepta los argumentos del script, por ej.:
#   ./Avid_MXF_Folder.command --cli "/Volumes/.../Proyecto" --dry-run
cd "$(dirname "$0")" || exit 1

# ---------------------------------------------------------------------------
# Python para los scripts de Avid (igual en Mac Intel y Apple Silicon).
# La primera vez crea un entorno propio en ~/.avid_scripts/venv con pyavb y
# pyaaf2 (necesita internet). Las siguientes veces arranca directo.
# Si algo se rompe (por ej. se actualizó Python), lo rearma solo.
# ---------------------------------------------------------------------------
VENV="$HOME/.avid_scripts/venv"
PY="$VENV/bin/python"
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

buscar_python() {
    for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
             /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
        if [ -x "$p" ] && "$p" -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then
            echo "$p"; return 0
        fi
    done
    # El python3 de Apple solo sirve si están las Command Line Tools;
    # si no, abriría el instalador de Apple en vez de correr.
    if [ -x /usr/bin/python3 ] && xcode-select -p >/dev/null 2>&1; then
        echo /usr/bin/python3; return 0
    fi
    return 1
}

preparar_python() {
    if [ -x "$PY" ] && "$PY" -c 'import avb, aaf2' 2>/dev/null; then
        return 0
    fi
    BASE=$(buscar_python)
    if [ -z "$BASE" ]; then
        echo "No encuentro Python 3 en esta Mac."
        echo "Instalalo desde https://www.python.org/downloads/macos/"
        echo "(el instalador \"macOS 64-bit universal2\" sirve para Intel y Apple Silicon)"
        echo "y después volvé a abrir este archivo."
        return 1
    fi
    echo "Preparando Python (solo la primera vez, necesita internet)..."
    rm -rf "$VENV"
    mkdir -p "$HOME/.avid_scripts"
    if ! "$BASE" -m venv "$VENV"; then
        echo "No se pudo crear el entorno de Python con $BASE"
        return 1
    fi
    if ! "$PY" -m pip install --disable-pip-version-check -q pyavb pyaaf2; then
        echo "No se pudieron instalar pyavb / pyaaf2. ¿Hay internet?"
        rm -rf "$VENV"
        return 1
    fi
    echo "Listo."
    echo
}

pausa() {
    echo
    read -r -p "Apretá Enter para cerrar esta ventana..." _
}
# ---------------------------------------------------------------------------

if preparar_python; then
    "$PY" ./Avid_MXF_Folder.py "$@"
fi
pausa
