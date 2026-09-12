//go:build darwin

package collector

import "syscall"

// diskUsage devuelve los bytes ocupados y disponibles del sistema de archivos
// montado en mountpoint (macOS, vía statfs). ok=false si no se pudo leer.
// used = (bloques totales − libres); avail = bloques disponibles a usuario.
//
// Es la misma cuenta que en Linux; se deja en un archivo aparte y no en un
// `//go:build linux || darwin` porque el port de macOS no toca los archivos de
// Linux (ver mejora-port-macos: cada equipo es dueño de su plataforma). En
// darwin, Bsize es uint32 y allá Blocks/Bfree/Bavail son uint64.
func diskUsage(mountpoint string) (used, avail uint64, ok bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(mountpoint, &st); err != nil {
		return 0, 0, false
	}
	bs := uint64(st.Bsize)
	if bs == 0 || st.Blocks == 0 {
		return 0, 0, false
	}
	used = (st.Blocks - st.Bfree) * bs
	avail = st.Bavail * bs
	return used, avail, true
}
