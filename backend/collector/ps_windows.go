//go:build windows

package collector

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

// Ayudantes para ejecutar los scripts de PowerShell EMBEBIDOS de los módulos de
// Windows (software instalado, controladores y redes WiFi). El del historial de
// errores tiene los suyos propios en errors_windows.go por su cuenta.
//
// Por qué PowerShell y no Go: Get-AppxPackage, Export-WindowsDriver y netsh
// resuelven en una línea cosas que en Go serían WMI + COM + parseo de salida
// localizada. El coste es materializar el .ps1 en un temporal.

var (
	psCacheMu sync.Mutex
	psCache   = map[string]string{} // nombre → ruta del .ps1 materializado
)

// materializaPS escribe un script embebido en un temporal (una sola vez por
// nombre) y devuelve su ruta.
//
// IMPORTANTE: se escribe con BOM UTF-8. Windows PowerShell 5.1 interpreta los
// .ps1 SIN BOM como ANSI y destrozaría todos los acentos de los textos.
func materializaPS(nombre string, contenido []byte) (string, error) {
	psCacheMu.Lock()
	defer psCacheMu.Unlock()
	if p, ok := psCache[nombre]; ok {
		return p, nil
	}
	f, err := os.CreateTemp("", "pcinfo-"+nombre+"-*.ps1")
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := f.Write([]byte("\ufeff")); err != nil {
		return "", err
	}
	if _, err := f.Write(contenido); err != nil {
		return "", err
	}
	psCache[nombre] = f.Name()
	return f.Name(), nil
}

// correPS ejecuta un script embebido y devuelve su salida estándar. Sin ventana
// de consola (el backend se compila con -H windowsgui: sin ocultaVentana
// aparecería una consola negra).
func correPS(nombre string, contenido []byte, espera time.Duration, args ...string) (string, error) {
	ps1, err := materializaPS(nombre, contenido)
	if err != nil {
		return "", fmt.Errorf("no se pudo preparar el script: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), espera)
	defer cancel()
	base := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ps1}
	cmd := exec.CommandContext(ctx, rutaPowerShell(), append(base, args...)...)
	ocultaVentana(cmd)
	out, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return string(out), fmt.Errorf("tardó demasiado (más de %s)", espera)
	}
	return string(out), err
}

// correPSFlujo ejecuta un script embebido informando de CADA línea que imprime,
// en vivo. Lo usan el respaldo y la restauración de controladores, que tardan
// minutos: sin esto la GUI solo podría mostrar un reloj de arena.
func correPSFlujo(ctx context.Context, nombre string, contenido []byte, linea func(string), args ...string) error {
	ps1, err := materializaPS(nombre, contenido)
	if err != nil {
		return fmt.Errorf("no se pudo preparar el script: %w", err)
	}
	base := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ps1}
	cmd := exec.CommandContext(ctx, rutaPowerShell(), append(base, args...)...)
	ocultaVentana(cmd)
	return correLineas(ctx, cmd, linea)
}

// tempPCInfo devuelve una carpeta temporal propia, creada al vuelo.
func tempPCInfo(prefijo string) (string, error) {
	return os.MkdirTemp(filepath.Clean(os.TempDir()), "pcinfo-"+prefijo+"-")
}
