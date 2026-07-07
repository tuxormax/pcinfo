//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// watchParent bloquea hasta que el proceso pid (la GUI) termina y entonces
// cierra el backend. Necesario en Windows: la GUI corre asInvoker y el backend
// puede correr ELEVADO (RunAs para SMART), así que la GUI no puede matarlo; el
// backend se autodestruye al ver que la GUI ya no existe. Si no se puede abrir
// el handle (permisos/PID inválido), simplemente no vigila.
func watchParent(pid int) {
	h, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return
	}
	defer windows.CloseHandle(h)
	windows.WaitForSingleObject(h, windows.INFINITE)
	os.Exit(0)
}
