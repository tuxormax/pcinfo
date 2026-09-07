//go:build !linux

package collector

import "runtime"

// collectBoots donde el módulo todavía no está implementado. En Windows lo
// mismo se saca del registro de eventos (6005 encendido, 6006 apagado ordenado,
// 6008 apagado inesperado, 1074 quién lo pidió, 41 corte de energía) y del
// Programador de tareas; queda pendiente para una revisión próxima.
//
// Se devuelve el motivo redactado en vez de una lista vacía: "sin datos" y "no
// implementado" se ven igual en pantalla, y confundirlos hace creer que el
// equipo nunca se ha apagado mal.
func collectBoots() BootsReport {
	return BootsReport{
		OS:        runtime.GOOS,
		Elevated:  isElevated(),
		Available: false,
		Source:    "no disponible",
		Reason: "El historial de encendidos y apagados todavía solo está implementado en Linux. " +
			"En Windows saldrá del registro de eventos y del Programador de tareas.",
		ScanDays: diasAnalisis,
		Sessions: []BootSession{},
		Tasks:    []AutoTask{},
		Startup:  []StartupItem{},
	}
}
