//go:build !darwin

package collector

// collectIncidenciasDarwin solo aplica en macOS. En Linux y Windows el dato
// existe igual y está pendiente de escribir:
//   - Linux: journald / dmesg — "I/O error", "blk_update_request",
//     "critical medium error", y las desconexiones de USB.
//   - Windows: registro de eventos del sistema — sucesos 7, 11, 51 y 153 de
//     `disk`, más los de `storahci`/`stornvme`.
//
// Mientras no estén, la ficha contesta con su motivo redactado, nunca en blanco.
func collectIncidenciasDarwin(horas int, _ []DiskInfo) IncidenciasDiscos {
	return IncidenciasDiscos{
		Horas: horas,
		Motivo: "El historial de incidencias de disco todavía solo está " +
			"implementado en macOS. En Linux saldrá de journald y en Windows del " +
			"registro de eventos.",
	}
}
