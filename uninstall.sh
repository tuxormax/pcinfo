#!/bin/bash
# LinuxHWMonitor — Desinstalador

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${YELLOW}  LinuxHWMonitor — Desinstalador${NC}"
echo -e "  ─────────────────────────────"
echo ""
read -rp "  ¿Desinstalar LinuxHWMonitor? [s/N] " resp
[[ ! "$resp" =~ ^[SsYy]$ ]] && echo "  Cancelado." && exit 0

rm -rf  "$HOME/.local/share/linuxhwmonitor"
rm -f   "$HOME/.local/bin/linuxhwmonitor"
rm -f   "$HOME/.local/share/applications/linuxhwmonitor.desktop"
rm -f   "$HOME/.local/share/icons/hicolor/scalable/apps/org.linuxhwmonitor.App.svg"
# Eliminar política polkit si fue instalada con sudo
sudo rm -f /usr/share/polkit-1/actions/org.linuxhwmonitor.policy 2>/dev/null || true
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo -e "${GREEN}  ✓  LinuxHWMonitor desinstalado correctamente.${NC}"
echo ""
