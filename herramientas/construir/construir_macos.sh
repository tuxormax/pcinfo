#!/usr/bin/env bash
# Construye PCInfo para macOS **universal** (Apple Silicon + Intel, un solo
# .app y un solo .dmg que corren en cualquier Mac) y lo deja listo para copiar,
# pegar e instalar. SOLO corre en un Mac (Flutter para macOS exige Xcode).
#
# Uso:  bash herramientas/construir/construir_macos.sh [--sin-dmg] [--refrescar-smartctl]
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
#
# ⭐ UNIVERSAL (12-Sep-2026): Flutter ya compila la GUI universal por su cuenta,
# pero el backend Go y smartctl había que fusionarlos a mano con `lipo`:
#   - Backend: se compila DOS VECES (arm64 y amd64) y se fusiona. No hace falta
#     nada externo, Go cruza solo.
#   - smartctl: no hay forma de tener un smartctl x86_64 nativo en un Apple
#     Silicon por la vía normal — Homebrew YA NO deja instalar una copia Intel
#     bajo Rosetta (`arch -x86_64 brew install…` falla con "Homebrew on macOS is
#     only supported on Apple Silicon processors!", cambio de Homebrew, no de
#     macOS). La salida: bajar DIRECTO la bottle x86_64 oficial de smartmontools
#     desde el registro de bottles de Homebrew (ghcr.io, mismo sitio de donde
#     `brew` los baja) sin pasar por `brew install`. Se cachea en
#     herramientas/construir/cache-macos/ para no volver a bajarla en cada build.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # script en herramientas/construir/
APP_DIR="$RAIZ/pcinfo"
BACK_DIR="$RAIZ/backend"
SALIDA="$RAIZ/instaladores"
CACHE="$RAIZ/herramientas/construir/cache-macos"
HACER_DMG=1
REFRESCAR_SMARTCTL=0
for arg in "$@"; do
  case "$arg" in
    --sin-dmg) HACER_DMG=0 ;;
    --refrescar-smartctl) REFRESCAR_SMARTCTL=1 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Este script solo corre en un Mac: Flutter para macOS necesita Xcode." >&2
  exit 1
fi

# Versión y revisión: un solo sitio, lib/version.dart (igual que Linux/Windows).
VERSION="$(sed -n "s/^const String appVersion = '\([^']*\)';/\1/p" "$APP_DIR/lib/version.dart")"
REVISION="$(sed -n "s/^const int appRevision = \([0-9]*\);/\1/p" "$APP_DIR/lib/version.dart")"
[[ -n "$VERSION" && -n "$REVISION" ]] || { echo "No pude leer la versión de lib/version.dart" >&2; exit 1; }
BASENAME="pcinfo_v${VERSION}_rev-${REVISION}_macos"
echo ">> PCInfo v$VERSION Rev $REVISION — macOS universal (compilando en $(uname -m))"

# 1) Backend Go, en las DOS arquitecturas, fusionado con lipo.
echo ">> Compilando el backend (arm64 + amd64)…"
LDFLAGS="-s -w -X main.buildVersion=$VERSION -X main.buildRevision=$REVISION"
( cd "$BACK_DIR" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags "$LDFLAGS" -o /tmp/pcinfo-backend-arm64 . )
( cd "$BACK_DIR" && CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags "$LDFLAGS" -o /tmp/pcinfo-backend-amd64 . )
lipo -create /tmp/pcinfo-backend-arm64 /tmp/pcinfo-backend-amd64 -output "$BACK_DIR/pcinfo-backend"
rm -f /tmp/pcinfo-backend-arm64 /tmp/pcinfo-backend-amd64

# 2) GUI Flutter (Flutter arma universal solo, sin nada que hacer aquí).
echo ">> Compilando la interfaz…"
( cd "$APP_DIR" && flutter build macos --release )
APP="$APP_DIR/build/macos/Build/Products/Release/PCInfo.app"
[[ -d "$APP" ]] || { echo "No se generó $APP" >&2; exit 1; }

# 3) smartctl universal: el arm64 sale de Homebrew local; el x86_64 se cachea o
#    se baja de la bottle oficial (no se puede `brew install` un Intel aquí).
echo ">> Preparando smartctl universal…"
mkdir -p "$CACHE"
SMARTCTL_ARM64=""
for cand in /opt/homebrew/bin/smartctl /usr/local/bin/smartctl; do
  [[ -x "$cand" ]] && { SMARTCTL_ARM64="$cand"; break; }
done

SMARTCTL_X86="$CACHE/smartctl-x86_64"
if [[ "$REFRESCAR_SMARTCTL" == "1" || ! -x "$SMARTCTL_X86" ]]; then
  echo "   descargando smartctl x86_64 (bottle oficial de Homebrew, una sola vez)…"
  URL_BOTTLE="$(curl -fsSL https://formulae.brew.sh/api/formula/smartmontools.json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin)['bottle']['stable']['files']; print(d.get('sonoma',d.get('ventura',{})).get('url',''))" 2>/dev/null || true)"
  if [[ -n "$URL_BOTTLE" ]]; then
    TOKEN="$(curl -fsSL 'https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/smartmontools:pull' \
      | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])" 2>/dev/null || true)"
    TMPBOT="$(mktemp -d)"
    if [[ -n "$TOKEN" ]] && curl -fsSL -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.oci.image.layer.v1.tar+gzip" \
        "$URL_BOTTLE" -o "$TMPBOT/bottle.tar.gz" 2>/dev/null; then
      tar -xzf "$TMPBOT/bottle.tar.gz" -C "$TMPBOT" 2>/dev/null || true
      BIN="$(find "$TMPBOT" -type f -path '*/bin/smartctl' | head -1)"
      if [[ -n "$BIN" ]]; then
        cp -f "$BIN" "$SMARTCTL_X86"
        chmod +x "$SMARTCTL_X86"
        echo "   ✓ smartctl x86_64 cacheado en $SMARTCTL_X86"
      fi
    fi
    rm -rf "$TMPBOT"
  fi
  [[ -x "$SMARTCTL_X86" ]] || echo "   ⚠️  no se pudo bajar smartctl x86_64 (sin red, o cambió la bottle). Se sigue con lo que haya."
fi

SMARTCTL_UNIVERSAL=""
if [[ -n "$SMARTCTL_ARM64" && -x "$SMARTCTL_X86" ]]; then
  SMARTCTL_UNIVERSAL="$CACHE/smartctl-universal"
  lipo -create "$SMARTCTL_ARM64" "$SMARTCTL_X86" -output "$SMARTCTL_UNIVERSAL"
  echo "   ✓ smartctl universal: $(lipo -info "$SMARTCTL_UNIVERSAL" | sed 's/^Architectures.*are: //')"
elif [[ -n "$SMARTCTL_ARM64" ]]; then
  SMARTCTL_UNIVERSAL="$SMARTCTL_ARM64"
  echo "   ⚠️  solo arm64: en un Mac Intel esta app saldría SIN salud de discos."
fi

# 4) Meter el backend y smartctl dentro del .app.
echo ">> Empaquetando backend y smartctl dentro del .app…"
cp -f "$BACK_DIR/pcinfo-backend" "$APP/Contents/MacOS/pcinfo-backend"
if [[ -n "$SMARTCTL_UNIVERSAL" ]]; then
  cp -f "$SMARTCTL_UNIVERSAL" "$APP/Contents/MacOS/smartctl"
  # La base de datos de discos de smartmontools, si está: mejora el modelo
  # reconocido en discos USB. Sin ella smartctl funciona igual. Es texto, no
  # binario: no importa de qué arquitectura salga.
  for cand in /opt/homebrew/opt/smartmontools/share/smartmontools/drivedb.h \
              /opt/homebrew/share/smartmontools/drivedb.h; do
    [[ -f "$cand" ]] && { cp -f "$cand" "$APP/Contents/MacOS/drivedb.h"; break; }
  done
else
  echo "   ⚠️  smartctl no encontrado: la app saldrá SIN salud de discos."
  echo "      Instálalo con 'brew install smartmontools' y vuelve a construir."
fi

# 5) Firma ad-hoc. Tocar el .app después de compilarlo invalida la firma que
#    puso Xcode, así que se vuelve a firmar todo (para uso propio basta la
#    ad-hoc: no cuesta nada y Gatekeeper la acepta abriendo con clic derecho).
echo ">> Firmando (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/pcinfo-backend"
[[ -f "$APP/Contents/MacOS/smartctl" ]] && codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/smartctl"
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null || \
  codesign --force --sign - --timestamp=none "$APP"

# 6) Copiar a instaladores/ y armar el .dmg.
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

echo ">> Listo. Arquitecturas del ejecutable:"
lipo -info "$SALIDA/PCInfo.app/Contents/MacOS/PCInfo" 2>/dev/null || file "$SALIDA/PCInfo.app/Contents/MacOS/PCInfo"
echo ">> Arquitecturas del backend:"
lipo -info "$SALIDA/PCInfo.app/Contents/MacOS/pcinfo-backend"
[[ -f "$SALIDA/PCInfo.app/Contents/MacOS/smartctl" ]] && { echo ">> Arquitecturas de smartctl:"; lipo -info "$SALIDA/PCInfo.app/Contents/MacOS/smartctl"; }
