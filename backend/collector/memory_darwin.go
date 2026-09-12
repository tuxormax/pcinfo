//go:build darwin

package collector

// enrichMemory en macOS: `ghw` no implementa memoria en darwin (devuelve error),
// así que el total sale de sysctl.
//
// ⛔ No hay lista de módulos ni de ranuras en un Apple Silicon: la RAM va dentro
// del propio SoC (memoria unificada). Se informa el total y se marca soldada;
// dejar TotalSlots en 0 es lo correcto — inventar "1 ranura" sería mentir.
// En los Mac Intel sí había módulos, pero eso se sacaría de
// `system_profiler SPMemoryDataType` y no se ha podido probar en un equipo real.
func enrichMemory(out *MemoryInfo) {
	if out.TotalBytes == 0 {
		out.TotalBytes = sysctlEntero("hw.memsize")
	}
	if out.UsableBytes == 0 {
		// memsize_usable descuenta lo que se reserva el firmware.
		if u := sysctlEntero("hw.memsize_usable"); u > 0 {
			out.UsableBytes = u
		} else {
			out.UsableBytes = out.TotalBytes
		}
	}
	out.Soldered = true
}
