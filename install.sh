#!/bin/bash
# ╔══════════════════════════════════════════════════════════╗
# ║   LinuxHWMonitor v1.2 Rev 2 — Instalador universal      ║
# ║   Compatible con: Debian/Ubuntu, Fedora/RHEL, Arch,     ║
# ║   openSUSE y cualquier distro Linux                      ║
# ╚══════════════════════════════════════════════════════════╝

set -e

# ── Colores ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC}  $1"; }
info() { echo -e "${BLUE}  ▶${NC}  $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC}  $1"; }
err()  { echo -e "${RED}  ✗${NC}  $1"; exit 1; }

# ── Detectar si se ejecuta desde gestor de archivos ──────
if [ ! -t 0 ]; then
    for term in gnome-terminal konsole xfce4-terminal xterm; do
        if command -v "$term" &>/dev/null; then
            "$term" -- bash "$0"; exit 0
        fi
    done
fi

clear
echo -e "${BOLD}${CYAN}"
echo "  ██╗     ██╗███╗   ██╗██╗   ██╗██╗  ██╗██╗  ██╗██╗    ██╗"
echo "  ██║     ██║████╗  ██║██║   ██║╚██╗██╔╝██║  ██║██║    ██║"
echo "  ██║     ██║██╔██╗ ██║██║   ██║ ╚███╔╝ ███████║██║ █╗ ██║"
echo "  ██║     ██║██║╚██╗██║██║   ██║ ██╔██╗ ██╔══██║██║███╗██║"
echo "  ███████╗██║██║ ╚████║╚██████╔╝██╔╝ ██╗██║  ██║╚███╔███╔╝"
echo "  ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚══╝╚══╝ "
echo -e "${NC}"
echo -e "${BOLD}  Hardware Monitor para Linux  —  v1.2 Rev 2${NC}"
echo -e "  ${BLUE}─────────────────────────────────────────────────${NC}"
echo ""

# ── Verificar root / sudo ────────────────────────────────
SUDO=""
if [ "$EUID" -ne 0 ]; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
        info "Se usará sudo para instalar."
    else
        warn "Sin sudo. Solo se instalará para el usuario actual."
    fi
fi

# ── Detectar distribución ─────────────────────────────────
info "Detectando distribución..."
if   command -v apt-get &>/dev/null; then DISTRO="deb"
elif command -v dnf     &>/dev/null; then DISTRO="rpm"
elif command -v pacman  &>/dev/null; then DISTRO="arch"
elif command -v zypper  &>/dev/null; then DISTRO="suse"
else DISTRO="unknown"; fi

case $DISTRO in
    deb)  ok "Distribución: Debian / Ubuntu" ;;
    rpm)  ok "Distribución: Fedora / RHEL / CentOS" ;;
    arch) ok "Distribución: Arch Linux / Manjaro" ;;
    suse) ok "Distribución: openSUSE" ;;
    *)    warn "Distribución no reconocida. Instalación manual de dependencias requerida." ;;
esac

# ── Instalar dependencias del sistema ─────────────────────
echo ""
info "Instalando dependencias del sistema..."

install_system_deps() {
    case $DISTRO in
        deb)
            $SUDO apt-get update -qq 2>/dev/null
            $SUDO apt-get install -y python3 python3-pip python3-pyqt5 \
                smartmontools lm-sensors pciutils dmidecode \
                libxcb-xinerama0 2>/dev/null
            ;;
        rpm)
            $SUDO dnf install -y python3 python3-pip python3-qt5 \
                smartmontools lm_sensors pciutils dmidecode 2>/dev/null
            ;;
        arch)
            $SUDO pacman -Sy --noconfirm python python-pip python-pyqt5 \
                smartmontools lm_sensors pciutils dmidecode 2>/dev/null
            ;;
        suse)
            $SUDO zypper install -y python3 python3-pip python3-qt5 \
                smartmontools sensors pciutils dmidecode 2>/dev/null
            ;;
        unknown)
            warn "Instala manualmente: python3-pyqt5 smartmontools lm-sensors pciutils dmidecode"
            ;;
    esac
}

install_system_deps && ok "Dependencias del sistema instaladas" || \
    warn "Algunas dependencias no se pudieron instalar (continúa de todos modos)"

# ── Instalar psutil via pip ────────────────────────────────
info "Instalando psutil..."
pip3 install --user --quiet psutil 2>/dev/null || \
pip3 install --user psutil 2>/dev/null || \
python3 -m pip install --user psutil 2>/dev/null || \
warn "psutil no se pudo instalar via pip"
ok "psutil listo"

# ── Detectar directorio del script ────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SRC="$SCRIPT_DIR/src/linux_hwmonitor.py"

if [ ! -f "$APP_SRC" ]; then
    APP_SRC="$SCRIPT_DIR/linux_hwmonitor.py"
fi
if [ ! -f "$APP_SRC" ]; then
    err "No se encontró linux_hwmonitor.py. Ejecuta este script desde la carpeta del proyecto."
fi

# ── Directorios de instalación ────────────────────────────
INSTALL_DIR="$HOME/.local/share/linuxhwmonitor"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
ICONS_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"

echo ""
info "Instalando en: $INSTALL_DIR"

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$APPS_DIR" "$ICONS_DIR"

# ── Copiar aplicación ─────────────────────────────────────
cp "$APP_SRC" "$INSTALL_DIR/linux_hwmonitor.py"
chmod 644 "$INSTALL_DIR/linux_hwmonitor.py"
ok "Aplicación copiada"

# ── Instalar wrapper del sistema (para Polkit) ────────────
WRAPPER_DST="/usr/local/bin/linuxhwmonitor-helper"
POLICY_DST="/usr/share/polkit-1/actions/org.linuxhwmonitor.policy"

if [ -n "$SUDO" ]; then
    $SUDO bash -c "cat > '$WRAPPER_DST'" << WRAPPER_EOF
#!/bin/bash
exec python3 "$INSTALL_DIR/linux_hwmonitor.py" "\$@"
WRAPPER_EOF
    $SUDO chmod 755 "$WRAPPER_DST"
    ok "Helper del sistema instalado en $WRAPPER_DST"

    POLICY_SRC="$SCRIPT_DIR/data/org.linuxhwmonitor.policy"
    if [ -f "$POLICY_SRC" ]; then
        $SUDO sed "s|WRAPPER_PATH_PLACEHOLDER|$WRAPPER_DST|g" \
            "$POLICY_SRC" > /tmp/linuxhwmonitor.policy.tmp
        $SUDO mv /tmp/linuxhwmonitor.policy.tmp "$POLICY_DST"
        ok "Política Polkit instalada"
    fi
else
    warn "Sin sudo: el mensaje del diálogo de contraseña será genérico"
fi

# ── Crear lanzador ─────────────────────────────────────────
cat > "$BIN_DIR/linuxhwmonitor" << LAUNCHER
#!/bin/bash
APP="$INSTALL_DIR/linux_hwmonitor.py"
HELPER="$WRAPPER_DST"

if [ "\$EUID" -eq 0 ]; then
    python3 "\$APP"
elif [ -x "\$HELPER" ] && command -v pkexec &>/dev/null; then
    pkexec env \\
        DISPLAY="\$DISPLAY" \\
        XAUTHORITY="\$XAUTHORITY" \\
        HOME="\$HOME" \\
        "\$HELPER"
    EC=\$?
    [ \$EC -eq 126 ] || [ \$EC -eq 127 ] && python3 "\$APP"
elif command -v sudo &>/dev/null; then
    sudo -E python3 "\$APP" 2>/dev/null || python3 "\$APP"
else
    python3 "\$APP"
fi
LAUNCHER
chmod 755 "$BIN_DIR/linuxhwmonitor"
ok "Lanzador creado en $BIN_DIR/linuxhwmonitor"

# ── Instalar ícono ────────────────────────────────────────
SVG_SRC="$SCRIPT_DIR/data/icons/org.linuxhwmonitor.App.svg"
if [ ! -f "$SVG_SRC" ]; then
    SVG_SRC="$SCRIPT_DIR/org.linuxhwmonitor.App.svg"
fi

if [ -f "$SVG_SRC" ]; then
    cp "$SVG_SRC" "$ICONS_DIR/org.linuxhwmonitor.App.svg"
    ok "Ícono instalado"
else
    cat > "$ICONS_DIR/org.linuxhwmonitor.App.svg" << 'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="22" fill="#0d1117"/>
  <rect width="128" height="128" rx="22" fill="none" stroke="#30363d" stroke-width="2"/>
  <rect x="40" y="40" width="48" height="48" rx="6" fill="#21262d" stroke="#30363d" stroke-width="1.5"/>
  <circle cx="64" cy="64" r="10" fill="#238636"/>
  <circle cx="64" cy="64" r="5" fill="#fff" opacity=".9"/>
</svg>
SVGEOF
    ok "Ícono generado"
fi

gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

# ── Crear entrada en el menú de aplicaciones ─────────────
cat > "$APPS_DIR/linuxhwmonitor.desktop" << DESKTOP
[Desktop Entry]
Name=LinuxHWMonitor
GenericName=Monitor de Hardware
Comment=Monitor S.M.A.R.T. y detección de hardware para Linux
Exec=$BIN_DIR/linuxhwmonitor
Icon=org.linuxhwmonitor.App
Terminal=false
Type=Application
Categories=System;Monitor;HardwareSettings;
Keywords=hardware;monitor;smart;disco;cpu;gpu;ram;temperatura;
StartupWMClass=LinuxHWMonitor
StartupNotify=true
DESKTOP
chmod 644 "$APPS_DIR/linuxhwmonitor.desktop"
update-desktop-database "$APPS_DIR" 2>/dev/null || true
ok "Acceso directo creado en el menú de aplicaciones"

# ── Agregar ~/.local/bin al PATH si hace falta ────────────
SHELL_RC=""
if [[ "$SHELL" == *"zsh"* ]]; then SHELL_RC="$HOME/.zshrc"
elif [[ "$SHELL" == *"bash"* ]]; then SHELL_RC="$HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ] && ! grep -q 'local/bin' "$SHELL_RC" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    ok "PATH actualizado en $SHELL_RC"
fi

export PATH="$HOME/.local/bin:$PATH"

# ── Resultado ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✓  Instalación completada exitosamente${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}¿Cómo abrir LinuxHWMonitor?${NC}"
echo ""
echo -e "  ${CYAN}►${NC}  Menú de aplicaciones → busca ${BOLD}LinuxHWMonitor${NC}"
echo -e "  ${CYAN}►${NC}  O desde terminal: ${BOLD}linuxhwmonitor${NC}"
echo ""
echo -e "  ${YELLOW}  Al abrirla te pedirá contraseña de administrador.${NC}"
echo -e "  ${YELLOW}  Esto es normal — necesita acceso para leer datos${NC}"
echo -e "  ${YELLOW}  S.M.A.R.T., temperatura y hardware del sistema.${NC}"
echo ""
echo -e "  ${BLUE}Para desinstalar: ejecuta ${BOLD}./uninstall.sh${NC}"
echo ""
echo -e "  ${BOLD}Presiona Enter para cerrar...${NC}"
read -r
