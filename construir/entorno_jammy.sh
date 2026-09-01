#!/usr/bin/env bash
# Entorno de compilacion Ubuntu 22.04 (jammy) para el .deb de Linux.
#
# POR QUE EXISTE
# --------------
# Un programa compilado contra una libreria del sistema NUEVA no arranca en un
# equipo con la version VIEJA; al reves si. Compilando en Mint 22.1 (GLib 2.80)
# el ejecutable pedia "g_once_init_enter_pointer", que no existe en Mint 21.3
# (GLib 2.72): la app moria antes de dibujar la ventana, sin mensaje alguno.
# Por eso el .deb se compila SIEMPRE dentro de un Ubuntu 22.04, la base mas
# vieja que se quiere soportar (Mint 21.x). El resultado corre igual en Mint 22.x.
#
# COMO FUNCIONA (sin root, sin Docker)
# ------------------------------------
# Se descarga el rootfs oficial de Ubuntu 22.04 y se entra con bwrap usando un
# espacio de nombres de usuario: dentro somos "root" para instalar paquetes
# (fakeroot tapa los chown que un usuario normal no puede hacer) y el usuario
# normal para compilar. No hace falta sudo ni demonio de contenedores.
#
# Uso:  source construir/entorno_jammy.sh   (define jammy_root y jammy_usuario)
#       PCINFO_ROOTFS=/otra/ruta para cambiar donde vive el entorno.

JAMMY_ROOTFS="${PCINFO_ROOTFS:-$HOME/.cache/pcinfo/jammy}"
JAMMY_TAR_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-amd64.tar.gz"
# Todo lo que "flutter build linux" y el backend Go necesitan. gcc va porque el
# backend se compila con cgo (igual que siempre); sin gcc Go lo desactivaria en
# silencio y el binario cambiaria de forma sin que nadie lo pidiera.
JAMMY_PAQUETES="clang gcc libc6-dev cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev ca-certificates curl git unzip xz-utils zip file"

# Ejecuta un comando dentro del entorno como root (para apt/dpkg).
jammy_root() {
  bwrap --unshare-user --uid 0 --gid 0 \
    --bind "$JAMMY_ROOTFS" / \
    --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
    --setenv HOME /root \
    --setenv PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --setenv DEBIAN_FRONTEND noninteractive \
    --setenv LANG C.UTF-8 \
    --chdir /root \
    /bin/bash -c "$*"
}

# Ejecuta un comando dentro del entorno como el usuario normal (para compilar).
# Monta el SDK de Flutter, el de Go, la cache de paquetes de Dart y el repo en
# las MISMAS rutas que en el equipo: package_config.json guarda rutas absolutas
# y no resolveria si el home cambiara de sitio.
jammy_usuario() {
  local repo="$1"; shift
  bwrap --unshare-user --uid "$(id -u)" --gid "$(id -g)" \
    --bind "$JAMMY_ROOTFS" / \
    --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
    --bind "$HOME/flutter"          "$HOME/flutter" \
    --bind "$HOME/go-sdk"           "$HOME/go-sdk" \
    --bind "$HOME/go"               "$HOME/go" \
    --bind "$HOME/.pub-cache"       "$HOME/.pub-cache" \
    --bind "$HOME/.config/flutter"  "$HOME/.config/flutter" \
    --bind "$repo"                  "$repo" \
    --setenv HOME "$HOME" \
    --setenv PATH "$HOME/go-sdk/go/bin:$HOME/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv LANG C.UTF-8 \
    --chdir "$repo" \
    /bin/bash -c "$*"
}

# Deja el entorno listo. Idempotente: la primera vez baja ~30 MB y unos 400 MB
# de paquetes; despues no hace nada.
jammy_preparar() {
  command -v bwrap >/dev/null 2>&1 || {
    echo "!! Falta bwrap (paquete bubblewrap), necesario para compilar en Ubuntu 22.04." >&2
    echo "   Instalalo con: sudo apt install bubblewrap" >&2
    return 1
  }

  if [ ! -f "$JAMMY_ROOTFS/.pcinfo-listo" ]; then
    echo ">> Preparando entorno Ubuntu 22.04 (solo la primera vez)..."
    mkdir -p "$(dirname "$JAMMY_ROOTFS")"
    local tar="$(dirname "$JAMMY_ROOTFS")/jammy-base.tar.gz"
    [ -f "$tar" ] || curl -# -L -o "$tar" "$JAMMY_TAR_URL"
    [ -d "$JAMMY_ROOTFS" ] && chmod -R u+w "$JAMMY_ROOTFS" 2>/dev/null
    rm -rf "$JAMMY_ROOTFS"; mkdir -p "$JAMMY_ROOTFS"
    # --no-same-owner: sin root no se puede dar propiedad a otros usuarios; asi
    # todo queda a nuestro nombre, que es justo lo que hace falta para escribir.
    tar --no-same-owner -xzf "$tar" -C "$JAMMY_ROOTFS"

    # apt cae con "setuid _apt" dentro del espacio de nombres: se le dice que no
    # use ese usuario de aislamiento.
    echo 'APT::Sandbox::User "root";' > "$JAMMY_ROOTFS/etc/apt/apt.conf.d/99-pcinfo"
    echo 'Acquire::Retries "3";'    >> "$JAMMY_ROOTFS/etc/apt/apt.conf.d/99-pcinfo"
    jammy_resolv

    jammy_root 'apt-get update -qq'
    # fakeroot: dpkg quiere hacer chown a usuarios que aqui no existen. Se baja
    # su .deb y se desempaqueta a mano porque instalarlo requeriria... fakeroot.
    jammy_root 'cd /root && apt-get download fakeroot libfakeroot >/dev/null 2>&1 && for d in *.deb; do dpkg-deb -x "$d" /; done && ln -sf fakeroot-sysv /usr/bin/fakeroot && rm -f *.deb'
    # El postinst de dbus no puede crear su usuario y devuelve error: no importa,
    # los archivos ya estan desempaquetados y compilar solo necesita eso.
    jammy_root "fakeroot apt-get install -y --no-install-recommends $JAMMY_PAQUETES 2>&1 | tail -3 || true"

    jammy_root 'pkg-config --modversion gtk+-3.0 >/dev/null && pkg-config --modversion glib-2.0 >/dev/null' \
      || { echo "!! El entorno Ubuntu 22.04 no quedo utilizable." >&2; return 1; }
    touch "$JAMMY_ROOTFS/.pcinfo-listo"
    echo ">> Entorno listo en $JAMMY_ROOTFS"
  fi

  jammy_resolv   # los DNS del equipo cambian; se refrescan en cada uso.
}

# El rootfs trae /etc/resolv.conf como enlace a /run, que aqui esta vacio: se
# reemplaza por el archivo real del equipo o no hay resolucion de nombres.
jammy_resolv() {
  rm -f "$JAMMY_ROOTFS/etc/resolv.conf"
  cp -L /etc/resolv.conf "$JAMMY_ROOTFS/etc/resolv.conf" 2>/dev/null \
    || echo "nameserver 1.1.1.1" > "$JAMMY_ROOTFS/etc/resolv.conf"
}
