package collector

import (
	"log"
	"runtime"
)

// Collect arma el inventario completo. Cada sub-colector degrada con elegancia:
// si una fuente falla (sin permisos, herramienta ausente, VM) devuelve lo que
// pudo y registra el motivo, pero nunca aborta el conjunto. Además cada colector
// corre envuelto en `safe()`: si entra en pánico (p. ej. una llamada WMI/COM en
// Windows) se recupera y devuelve el valor cero de esa sección, en vez de tumbar
// toda la respuesta /hardware (lo que haría que la GUI cayera al mock).
func Collect() HardwareInfo { return collect(true) }

// CollectSinSmart devuelve el inventario OMITIENDO la salud de los discos
// (S.M.A.R.T.), que es lo único lento: consultar un disco que no contesta —un
// lector de tarjetas, un gabinete USB— puede llevarse segundos por cada tipo de
// conexión que se prueba. La GUI lo usa para abrir de inmediato y pide la salud
// después, con /discos, actualizando la ficha cuando llega.
func CollectSinSmart() HardwareInfo { return collect(false) }

// CollectDiscos devuelve SOLO los discos, ya con S.M.A.R.T. Es la segunda parte
// del arranque en dos tiempos.
func CollectDiscos() []DiskInfo {
	return safe("disks", func() []DiskInfo { return collectDisks(true) })
}

func collect(conSmart bool) HardwareInfo {
	// La placa se recoge primero: la memoria la necesita para consultar el
	// catálogo de placas (ranuras y capacidad máxima verificadas).
	board := safe("board", collectBoard)
	return HardwareInfo{
		System: safe("system", collectSystem),
		CPU:    safe("cpu", collectCPU),
		Board:  board,
		Memory: safe("memory", func() MemoryInfo { return collectMemory(board) }),
		GPU:    safe("gpu", collectGPU),
		Disks:  safe("disks", func() []DiskInfo { return collectDisks(conSmart) }),
		Diag:   safe("diag", collectDiag),
	}
}

// collectDiag reúne los diagnósticos del recolector (elevación, smartctl). Sirve
// a la GUI para explicar por qué un disco salió "SIN SMART" y ofrecer solución.
func collectDiag() DiagInfo {
	return DiagInfo{
		OS:            runtime.GOOS,
		Elevated:      isElevated(),
		SmartctlFound: smartctlAvailable(),
	}
}

// safe ejecuta fn recuperándose de un pánico; si lo hay, lo registra y devuelve
// el valor cero de T (sección vacía) para no abortar el inventario completo.
func safe[T any](area string, fn func() T) (out T) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[colector:%s] pánico recuperado: %v", area, r)
		}
	}()
	return fn()
}

// warn registra una advertencia no fatal de un colector.
func warn(area string, err error) {
	if err != nil {
		log.Printf("[colector:%s] %v", area, err)
	}
}
