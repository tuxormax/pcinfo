//go:build windows

package collector

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// instalaPaqueteWeb instala un paquete ya descargado y verificado. El trabajo
// (firma Authenticode, Expand-Archive, pnputil, msiexec) lo hace la acción
// InstalarWeb del script, igual que el resto del módulo.
func instalaPaqueteWeb(ctx context.Context, d DriverWeb, archivo string) error {
	trabajo := filepath.Join(filepath.Dir(archivo), d.ID+"-x")
	if err := os.MkdirAll(trabajo, 0o755); err != nil {
		return fmt.Errorf("no se pudo preparar la carpeta de trabajo: %w", err)
	}
	defer os.RemoveAll(trabajo) // lo extraído sobra; el paquete descargado se conserva
	// Los valores van con «-Param:valor» y no como dos argumentos: un valor que
	// empieza por «-» o «/» ("-s", "/S") PowerShell lo tomaría por otro parámetro.
	extra := []string{"-Archivo:" + archivo, "-Tipo:" + d.Tipo}
	if d.Args != "" {
		extra = append(extra, "-Argumentos:"+d.Args)
	}
	if d.Ejecuta != "" {
		extra = append(extra, "-Ejecuta:"+d.Ejecuta)
		if d.EjecutaArgs != "" {
			extra = append(extra, "-EjecutaArgs:"+d.EjecutaArgs)
		}
	}
	if len(d.Exitos) > 0 {
		ns := make([]string, len(d.Exitos))
		for i, n := range d.Exitos {
			ns[i] = strconv.Itoa(n)
		}
		extra = append(extra, "-Exitos:"+strings.Join(ns, ","))
	}
	return tareaPS(ctx, "InstalarWeb", trabajo, extra...)
}
