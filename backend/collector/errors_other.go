//go:build !windows && !linux

package collector

import "runtime"

// collectErrors en plataformas sin implementación (macOS, BSD): devuelve un
// reporte vacío pero explicando por qué, para que la GUI no muestre "0 errores"
// como si el equipo estuviera impecable.
func collectErrors() ErrorsReport {
	return ErrorsReport{
		OS:        runtime.GOOS,
		Elevated:  isElevated(),
		Available: false,
		Source:    "no disponible",
		Reason:    "El historial de errores solo está implementado en Windows y Linux.",
		ScanDays:  diasAnalisis,
		Items:     []SystemError{},
		Dumps:     []DumpFile{},
	}
}
