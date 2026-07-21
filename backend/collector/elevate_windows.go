//go:build windows

package collector

import "golang.org/x/sys/windows"

// isElevated indica si el proceso corre con token de ADMINISTRADOR (elevado).
// En Windows, sin elevación smartctl no puede abrir los discos físicos y todos
// salen "SIN SMART". Consultamos la elevación del token del proceso
// (TokenElevation): con UAC, un admin NO elevado tiene un token filtrado que da
// false; solo cuando el proceso corre realmente elevado devuelve true. Es justo
// la distinción que la GUI necesita para ofrecer "Reintentar como administrador".
func isElevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}
