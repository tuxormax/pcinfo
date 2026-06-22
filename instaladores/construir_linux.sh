#!/usr/bin/env bash
# Construye el instalador .deb de PCInfo (GUI Flutter + backend Go).
# Uso: ./construir_linux.sh    (desde cualquier ruta)
# Requiere: flutter (desktop linux), go, dpkg-deb.
set -euo pipefail

VERSION="1.1.0"
ARCH="amd64"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # raíz del repo
APP_DIR="$ROOT/pcinfo"
BACKEND_DIR="$ROOT/backend"
OUT_DIR="$ROOT/instaladores"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

export PATH="$HOME/go-sdk/go/bin:$HOME/flutter/bin:$PATH"

echo ">> Compilando backend Go (linux/amd64)..."
( cd "$BACKEND_DIR" && GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o "$STAGE/pcinfo-backend" . )

echo ">> Compilando GUI Flutter (release)..."
( cd "$APP_DIR" && flutter build linux --release )
BUNDLE="$APP_DIR/build/linux/x64/release/bundle"

echo ">> Armando árbol del paquete .deb..."
PKG="$STAGE/pkg"
mkdir -p "$PKG/DEBIAN" \
         "$PKG/opt/pcinfo/app" \
         "$PKG/opt/pcinfo/backend" \
         "$PKG/usr/bin" \
         "$PKG/usr/share/applications" \
         "$PKG/lib/systemd/system"

cp -r "$BUNDLE/." "$PKG/opt/pcinfo/app/"
cp "$STAGE/pcinfo-backend" "$PKG/opt/pcinfo/backend/pcinfo-backend"
chmod 755 "$PKG/opt/pcinfo/backend/pcinfo-backend"

# Lanzador de la GUI.
cat > "$PKG/usr/bin/pcinfo" <<'EOF'
#!/bin/sh
exec /opt/pcinfo/app/pcinfo "$@"
EOF
chmod 755 "$PKG/usr/bin/pcinfo"

# Entrada de menú.
cat > "$PKG/usr/share/applications/pcinfo.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PCInfo
Comment=Inventario de hardware (CPU, RAM, placa, GPU, discos S.M.A.R.T.)
Exec=/usr/bin/pcinfo
Icon=pcinfo
Categories=System;Utility;
Terminal=false
EOF

# Servicio del backend (root → acceso a dmidecode y smartctl).
cat > "$PKG/lib/systemd/system/pcinfo-backend.service" <<'EOF'
[Unit]
Description=PCInfo backend (inventario de hardware en 127.0.0.1:51247)
After=network.target

[Service]
ExecStart=/opt/pcinfo/backend/pcinfo-backend --addr 127.0.0.1:51247
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

# Metadatos del paquete.
cat > "$PKG/DEBIAN/control" <<EOF
Package: pcinfo
Version: $VERSION
Architecture: $ARCH
Maintainer: tuxor <tuxor.max@gmail.com>
Section: utils
Priority: optional
Depends: libgtk-3-0, smartmontools, dmidecode
Description: PCInfo - inventario de hardware
 Monitor/inventario de hardware multiplataforma (CPU, RAM, tarjeta madre,
 GPU y discos con salud S.M.A.R.T.). GUI Flutter + backend Go.
EOF

# Activar/desactivar el servicio en instalación/desinstalación.
cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
systemctl daemon-reload || true
systemctl enable --now pcinfo-backend.service || true
exit 0
EOF
cat > "$PKG/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
systemctl disable --now pcinfo-backend.service || true
exit 0
EOF
cat > "$PKG/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
systemctl daemon-reload || true
exit 0
EOF
chmod 755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postrm"

DEB="$OUT_DIR/pcinfo_${VERSION}_${ARCH}.deb"
echo ">> Generando $DEB ..."
dpkg-deb --build --root-owner-group "$PKG" "$DEB"
echo ">> Listo: $DEB"
