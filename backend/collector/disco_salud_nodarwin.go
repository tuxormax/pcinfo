//go:build !darwin

package collector

// motivoSinSaludDarwin solo aplica en macOS, donde los motivos genéricos no
// sirven (ver disco_salud_darwin.go). Devolver "" deja que se use el motivo
// normal. Stub para que compile en el resto.
func motivoSinSaludDarwin(_ *DiskInfo) string { return "" }
