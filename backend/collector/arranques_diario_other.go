//go:build !linux

package collector

// activaDiarioPersistente solo aplica a Linux: el diario volátil es cosa de
// journald. En Windows el registro de eventos ya se guarda en disco siempre.
func activaDiarioPersistente() ResultadoAccion {
	return ResultadoAccion{
		Ok:      false,
		Message: "Esto solo aplica a Linux: en Windows el registro de eventos ya se conserva.",
	}
}
