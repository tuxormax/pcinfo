//go:build !windows

package collector

import "os/exec"

// ocultaVentana no hace nada fuera de Windows: en Linux/macOS los procesos hijo
// no abren ventana de consola. Existe para que los colectores compartidos
// (smart, gpu) llamen a una sola función sin condicionar por plataforma.
func ocultaVentana(_ *exec.Cmd) {}
