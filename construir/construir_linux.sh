#!/usr/bin/env bash
# Construye el instalador .deb de PCInfo (GUI Flutter + backend Go).
# Uso: ./construir_linux.sh [--sin-publicar]   (desde cualquier ruta)
# Requiere: flutter (desktop linux), go, dpkg-deb. Para publicar, ademas: gh.
#
# Al terminar sube el .deb al GitHub Release "v<ver>-rev<rev>" (el mismo donde el
# CI deja el .exe y el .zip portable): los instaladores NO viven en el repo, solo
# en Releases, y ahi se quedan. Con --sin-publicar solo lo deja en instaladores/.
set -euo pipefail

ARCH="amd64"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # raíz del repo
APP_DIR="$ROOT/pcinfo"

# Versión y revisión desde version.dart (única fuente de verdad, igual que el
# workflow de Windows). Así el .deb se nombra idéntico al .exe.
VERSION="$(grep -oP "appVersion = '\K[^']+" "$APP_DIR/lib/version.dart")"
REVISION="$(grep -oP "appRevision = \K[0-9]+" "$APP_DIR/lib/version.dart")"
DEB_VERSION="${VERSION}.${REVISION}"            # versión Debian válida (p.ej. 1.1.6)
BASENAME="pcinfo_v${VERSION}_rev-${REVISION}"   # mismo nombre base que Windows
BACKEND_DIR="$ROOT/backend"
OUT_DIR="$ROOT/instaladores"                    # carpeta LOCAL de salida (ignorada por git)
PUBLICAR=1
[ "${1:-}" = "--sin-publicar" ] && PUBLICAR=0
mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

export PATH="$HOME/go-sdk/go/bin:$HOME/flutter/bin:$PATH"

# TODO se compila dentro de un Ubuntu 22.04 (ver construir/entorno_jammy.sh).
# Compilar en el equipo (Mint 22.1 = Ubuntu 24.04) produce un binario que NO
# ARRANCA en Mint 21.x: pide simbolos de GLib 2.80 que en GLib 2.72 no existen,
# y muere sin mostrar nada. Al reves si funciona, asi que se usa la base vieja.
# shellcheck source=entorno_jammy.sh
. "$ROOT/construir/entorno_jammy.sh"
jammy_preparar

echo ">> Compilando backend Go (linux/amd64) en Ubuntu 22.04..."
# -X main.build* = versión/revisión dentro del backend: /healthz la publica y la
# GUI detecta así un backend viejo ocupando el puerto tras actualizar.
jammy_usuario "$ROOT" "cd '$BACKEND_DIR' && GOOS=linux GOARCH=amd64 go build \
    -ldflags=\"-s -w -X main.buildVersion=$VERSION -X main.buildRevision=$REVISION\" \
    -o '$ROOT/pcinfo-backend.tmp' ."
mv "$ROOT/pcinfo-backend.tmp" "$STAGE/pcinfo-backend"

echo ">> Compilando GUI Flutter (release) en Ubuntu 22.04..."
# flutter clean: la cache de CMake guarda rutas y compilador del ultimo entorno.
# Si quedo una compilacion hecha en el equipo, se reusaria y volveria a colarse
# la GLib nueva.
jammy_usuario "$ROOT" "cd '$APP_DIR' && flutter clean >/dev/null && flutter build linux --release"
BUNDLE="$APP_DIR/build/linux/x64/release/bundle"

echo ">> Verificando que nada pida simbolos que Ubuntu 22.04 no tenga..."
# Red de seguridad: ldd -r resuelve TODOS los simbolos contra las librerias del
# Ubuntu 22.04 del entorno. Si falta uno, el .deb no llega a generarse en vez de
# entregar un programa que no abre.
FALLOS="$(jammy_usuario "$ROOT" "
  for f in '$BUNDLE/pcinfo' '$BUNDLE'/lib/*.so '$STAGE/pcinfo-backend'; do
    [ -f \"\$f\" ] || continue
    LD_LIBRARY_PATH='$BUNDLE/lib' ldd -r \"\$f\" 2>&1 | grep -iE 'not found|undefined symbol' | sed \"s|^|\$(basename \$f): |\"
  done" || true)"
if [ -n "$FALLOS" ]; then
  echo "!! El binario pide cosas que Ubuntu 22.04 no tiene; NO se genera el .deb:" >&2
  echo "$FALLOS" >&2
  exit 1
fi
echo ">> Verificado: corre en Mint 21.x y en Mint 22.x."

echo ">> Armando árbol del paquete .deb..."
PKG="$STAGE/pkg"
mkdir -p "$PKG/DEBIAN" \
         "$PKG/opt/pcinfo/app" \
         "$PKG/opt/pcinfo/backend" \
         "$PKG/usr/bin" \
         "$PKG/usr/share/applications" \
         "$PKG/usr/share/icons/hicolor/256x256/apps" \
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

# Icono de la app (triángulo de seis + monitor). El .desktop lo referencia por
# nombre "pcinfo" → se instala en el tema hicolor.
cp "$APP_DIR/assets/icon/pcinfo_256.png" "$PKG/usr/share/icons/hicolor/256x256/apps/pcinfo.png"

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

# Version minima de las librerias contra las que se acaba de compilar. Sin esto,
# en un equipo demasiado viejo el paquete se instala y luego el programa no abre
# sin decir por que; declarandolas, el instalador lo rechaza con un mensaje claro.
# (En Ubuntu 24.04 los paquetes se llaman ...t64, pero declaran "Provides" con su
# version, asi que estas dependencias se satisfacen igual.)
GTK_MIN="$(jammy_usuario "$ROOT" 'pkg-config --modversion gtk+-3.0')"
GLIB_MIN="$(jammy_usuario "$ROOT" 'pkg-config --modversion glib-2.0')"
echo ">> Requiere GTK >= $GTK_MIN y GLib >= $GLIB_MIN"

# Metadatos del paquete.
cat > "$PKG/DEBIAN/control" <<EOF
Package: pcinfo
Version: $DEB_VERSION
Architecture: $ARCH
Maintainer: tuxor <tuxor.max@gmail.com>
Section: utils
Priority: optional
Depends: libgtk-3-0 (>= $GTK_MIN), libglib2.0-0 (>= $GLIB_MIN), smartmontools, dmidecode
Description: PCInfo - inventario de hardware
 Monitor/inventario de hardware multiplataforma (CPU, RAM, tarjeta madre,
 GPU y discos con salud S.M.A.R.T.). GUI Flutter + backend Go.
EOF

# Activar/desactivar el servicio en instalación/desinstalación.
cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
systemctl daemon-reload || true
systemctl enable pcinfo-backend.service || true
# restart (no "enable --now"): si el servicio ya corría con el binario viejo,
# "start" sería no-op y se quedaría el proceso anterior. restart SIEMPRE recarga
# el binario nuevo tras una actualización.
systemctl restart pcinfo-backend.service || true
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

DEB="$OUT_DIR/${BASENAME}.deb"
echo ">> Generando $DEB ..."
dpkg-deb --build --root-owner-group "$PKG" "$DEB"
echo ">> Listo: $DEB"

# Publicar en el Release de esta revision (mismo tag que el instalador Windows).
# Si el release aun no existe (todavia no corrio el CI de Windows) se crea aqui;
# el CI despues sube el .exe/.zip al mismo tag. Los releases NO se borran.
TAG="v${VERSION}-rev${REVISION}"
if [ "$PUBLICAR" = "1" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "!! gh no esta instalado: el .deb NO se publico. Subelo con:"
    echo "   gh release upload $TAG \"$DEB\" --clobber"
  else
    echo ">> Publicando en el release $TAG ..."
    gh release create "$TAG" "$DEB" \
      --title "PCInfo v${VERSION} Rev ${REVISION}" \
      --notes "Instalador .deb de Linux. El .exe y el .zip portable de Windows los sube el CI a este mismo release." \
      2>/dev/null \
      || gh release upload "$TAG" "$DEB" --clobber

    # Copia con NOMBRE FIJO ademas de la versionada: es la unica forma de que el
    # enlace directo del README no caduque en cada revision, porque GitHub
    # resuelve "latest/download/<nombre>" solo con el nombre EXACTO.
    FIJO="$OUT_DIR/PCInfo-Linux.deb"
    cp "$DEB" "$FIJO"
    gh release upload "$TAG" "$FIJO" --clobber
    echo ">> Publicado: https://github.com/tuxormax/pcinfo/releases/tag/$TAG"
  fi
else
  echo ">> (--sin-publicar) el .deb se quedo solo en $OUT_DIR"
fi
