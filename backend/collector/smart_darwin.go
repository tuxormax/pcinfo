//go:build darwin

package collector

import (
	"os"
	"os/exec"
	"path/filepath"
)

// rutasSmartctlDarwin: dónde buscar smartctl en un Mac, en orden.
//  1. Junto al propio backend — es donde lo dejará el .app entregado
//     (Contents/MacOS/), igual que hace el portable de Windows.
//  2. El PATH, para el flujo de desarrollo desde la terminal.
//  3. Las rutas de Homebrew a pelo: una app abierta desde el FINDER hereda un
//     PATH mínimo (/usr/bin:/bin:/usr/sbin:/sbin) que NO incluye
//     /opt/homebrew/bin, así que sin esto el smartctl instalado no aparece y
//     todos los discos saldrían "SIN SMART" aunque esté puesto.
//     /opt/homebrew es Apple Silicon; /usr/local, los Mac Intel.
var rutasSmartctlDarwin = []string{
	"/opt/homebrew/bin/smartctl",
	"/opt/homebrew/sbin/smartctl",
	"/usr/local/bin/smartctl",
	"/usr/local/sbin/smartctl",
	"/usr/sbin/smartctl",
}

func resolveSmartctlDarwin() {
	if exe, err := os.Executable(); err == nil {
		cand := filepath.Join(filepath.Dir(exe), "smartctl")
		if st, err := os.Stat(cand); err == nil && !st.IsDir() {
			smartctlPath = cand
			smartctlFound = true
			return
		}
	}
	if ruta, err := exec.LookPath("smartctl"); err == nil {
		smartctlPath = ruta
		smartctlFound = true
		return
	}
	for _, r := range rutasSmartctlDarwin {
		if st, err := os.Stat(r); err == nil && !st.IsDir() {
			smartctlPath = r
			smartctlFound = true
			return
		}
	}
}
