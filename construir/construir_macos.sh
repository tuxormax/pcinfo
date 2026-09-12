#!/usr/bin/env bash
# Construye PCInfo para macOS: backend Go + GUI Flutter dentro de un .app, y un
# .dmg para repartirlo. SOLO corre en un Mac (Flutter para macOS exige Xcode).
#
# Uso:  bash construir/construir_macos.sh [--sin-dmg]
#
# Qué deja en instaladores/ (carpeta local, no va al repositorio):
#   PCInfo.app                        la aplicación lista para usar
#   pcinfo_v<VER>_rev-<REV>_macos.dmg la misma app en un .dmg
#
# ⛔ El backend va DENTRO del .app (Contents/MacOS/), como el portable de
# Windows: proceso hijo de la GUI, sin servicio y sin pedir contraseña.
# ⛔ smartctl también se copia dentro: una app abierta desde el Finder recibe un
# PATH mínimo que NO incluye /opt/homebrew/bin, así que el smartctl instalado con
# Homebrew no se encontraría y todos los discos saldrían "SIN SMART".
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$RAIZ/pcinfo"
BACK_DIR="$RAIZ/backend"
SALIDA="$RAIZ/instaladores"
HACER_DMG=1
[[ "${1:-}" == "--sin-dmg" ]] && HACER_DMG=0

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Este script solo corre en un Mac: Flutter para macOS necesita Xcode." >&2
  exit 1
fi

# Versión y revisión: un solo sitio, lib/version.dart (igual que Linux/Windows).
VERSION="$(sed -n "s/^const String appVersion = '\([^']*\)';/\1/p" "$APP_DIR/lib/version.dart")"
REVISION="$(sed -n "s/^const int appRevision = \([0-9]*\);/\1/p" "$APP_DIR/lib/version.dart")"
[[ -n "$VERSION" && -n "$REVISION" ]] || { echo "No pude leer la versión de lib/version.dart" >&2; exit 1; }
BASENAME="pcinfo_v${VERSION}_rev-${REVISION}_macos"
echo ">> PCInfo v$VERSION Rev $REVISION — macOS ($(uname -m))"

# 1) Backend Go, nativo del Mac que compila.
echo ">> Compilando el backend…"
( cd "$BACK_DIR" && CGO_ENABLED=0 go build \
    -ldflags "-s -w -X main.buildVersion=$VERSION -X main.buildRevision=$REVISION" \
    -o "$BACK_DIR/pcinfo-backend" . )

# 2) GUI Flutter.
echo ">> Compilando la interfaz…"
( cd "$APP_DIR" && flutter build macos --release )
APP="$APP_DIR/build/macos/Build/Products/Release/PCInfo.app"
[[ -d "$APP" ]] || { echo "No se generó $APP" >&2; exit 1; }

# 3) Meter el backend y smartctl dentro del .app.
echo ">> Empaquetando backend y smartctl dentro del .app…"
cp -f "$BACK_DIR/pcinfo-backend" "$APP/Contents/MacOS/pcinfo-backend"
SMARTCTL="$(command -v smartctl || true)"
for cand in /opt/homebrew/bin/smartctl /usr/local/bin/smartctl; do
  [[ -n "$SMARTCTL" ]] && break
  [[ -x "$cand" ]] && SMARTCTL="$cand"
done
if [[ -n "$SMARTCTL" ]]; then
  cp -f "$SMARTCTL" "$APP/Contents/MacOS/smartctl"
  # La base de datos de discos de smartmontools, si está: mejora el modelo
  # reconocido en discos USB. Sin ella smartctl funciona igual.
  DB="$(dirname "$SMARTCTL")/../share/smartmontools/drivedb.h"
  [[ -f "$DB" ]] && cp -f "$DB" "$APP/Contents/MacOS/drivedb.h"
else
  echo "   ⚠️  smartctl no encontrado: la app saldrá SIN salud de discos."
  echo "      Instálalo con 'brew install smartmontools' y vuelve a construir."
fi

# 4) Firma ad-hoc. Tocar el .app después de compilarlo invalida la firma que
#    puso Xcode, así que se vuelve a firmar todo (para uso propio basta la
#    ad-hoc: no cuesta nada y Gatekeeper la acepta abriendo con clic derecho).
echo ">> Firmando (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/pcinfo-backend"
[[ -f "$APP/Contents/MacOS/smartctl" ]] && codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/smartctl"
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null || \
  codesign --force --sign - --timestamp=none "$APP"

# 5) Copiar a instaladores/ y armar el .dmg.
mkdir -p "$SALIDA"
rm -rf "$SALIDA/PCInfo.app"
cp -R "$APP" "$SALIDA/PCInfo.app"
echo ">> $SALIDA/PCInfo.app"

if [[ "$HACER_DMG" == "1" ]]; then
  echo ">> Armando el .dmg…"
  TMP="$(mktemp -d)"
  cp -R "$APP" "$TMP/PCInfo.app"
  ln -s /Applications "$TMP/Aplicaciones"
  rm -f "$SALIDA/$BASENAME.dmg"
  hdiutil create -volname "PCInfo $VERSION" -srcfolder "$TMP" \
    -ov -format UDZO -quiet "$SALIDA/$BASENAME.dmg"
  rm -rf "$TMP"
  cp -f "$SALIDA/$BASENAME.dmg" "$SALIDA/PCInfo-macOS.dmg"
  echo ">> $SALIDA/$BASENAME.dmg  (+ copia con nombre fijo PCInfo-macOS.dmg)"
fi

echo ">> Listo."
