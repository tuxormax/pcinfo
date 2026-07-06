//go:build !linux && !windows

package collector

// enrichMemory (otras plataformas) no añade detalle de ranuras: la ficha queda
// con los totales que dio ghw.
func enrichMemory(out *MemoryInfo) {}
