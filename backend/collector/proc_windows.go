//go:build windows

package collector

import (
	"os/exec"
	"syscall"
)

// createNoWindow (CREATE_NO_WINDOW) evita que un proceso hijo de consola
// (smartctl, nvidia-smi) reserve y muestre su propia ventana negra cuando el
// backend corre como GUI (-H windowsgui, sin consola que heredar). Sin esto,
// cada llamada parpadea —o deja fija— una consola durante la detección de
// hardware. Ref: docs de CreateProcess (dwCreationFlags).
const createNoWindow = 0x08000000

// ocultaVentana marca el comando para que no abra ventana de consola en Windows.
func ocultaVentana(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.HideWindow = true
	cmd.SysProcAttr.CreationFlags |= createNoWindow
}
