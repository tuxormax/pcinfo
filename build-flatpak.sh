#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  LinuxHWMonitor — Build y publicación Flatpak (local)
# ─────────────────────────────────────────────────────────────
set -e

APP_ID="org.linuxhwmonitor.App"
MANIFEST="flatpak/org.linuxhwmonitor.App.json"
BUILD_DIR=".flatpak-build"
REPO_DIR=".flatpak-repo"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  LinuxHWMonitor — Flatpak Build"
echo "═══════════════════════════════════════════════════════"

# Check dependencies
for cmd in flatpak flatpak-builder; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "✗  Falta: $cmd"
        echo "   Instala con: sudo apt install flatpak flatpak-builder"
        exit 1
    fi
done

# Add Flathub if needed
if ! flatpak remotes | grep -q flathub; then
    echo "▶  Agregando Flathub..."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

# Install SDK runtime
echo "▶  Instalando SDK runtime org.freedesktop.Platform/23.08 ..."
flatpak install -y flathub org.freedesktop.Platform//23.08 org.freedesktop.Sdk//23.08 || true

# Build
echo "▶  Construyendo Flatpak..."
flatpak-builder \
    --force-clean \
    --repo="$REPO_DIR" \
    --state-dir=".flatpak-state" \
    "$BUILD_DIR" \
    "$MANIFEST"

# Create bundle
echo "▶  Creando bundle .flatpak..."
flatpak build-bundle \
    "$REPO_DIR" \
    "linuxhwmonitor.flatpak" \
    "$APP_ID"

# Install locally (optional)
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✓  Build exitoso: linuxhwmonitor.flatpak"
echo ""
echo "  Instalar:  flatpak install --user linuxhwmonitor.flatpak"
echo "  Ejecutar:  flatpak run org.linuxhwmonitor.App"
echo "  Desinstalar: flatpak uninstall org.linuxhwmonitor.App"
echo "═══════════════════════════════════════════════════════"
echo ""

read -rp "¿Instalar ahora? [s/N] " resp
if [[ "$resp" =~ ^[sS]$ ]]; then
    flatpak install --user -y "linuxhwmonitor.flatpak"
    echo "✓  Instalado. Ejecuta: flatpak run $APP_ID"
fi
