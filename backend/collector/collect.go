package collector

import "log"

// Collect arma el inventario completo. Cada sub-colector degrada con elegancia:
// si una fuente falla (sin permisos, herramienta ausente, VM) devuelve lo que
// pudo y registra el motivo, pero nunca aborta el conjunto.
func Collect() HardwareInfo {
	return HardwareInfo{
		System: collectSystem(),
		CPU:    collectCPU(),
		Board:  collectBoard(),
		Memory: collectMemory(),
		GPU:    collectGPU(),
		Disks:  collectDisks(),
	}
}

// warn registra una advertencia no fatal de un colector.
func warn(area string, err error) {
	if err != nil {
		log.Printf("[colector:%s] %v", area, err)
	}
}
