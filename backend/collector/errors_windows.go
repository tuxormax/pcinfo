//go:build windows

package collector

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// Historial de errores en Windows. El trabajo pesado lo hace un script de
// PowerShell EMBEBIDO (errores_windows.ps1), portado de www/windows/bluescreen.ps1:
// lee el registro de eventos, localiza los .dmp del pantallazo azul, deduce el
// driver culpable leyendo el volcado y traduce cada STOP code a "causa + cómo
// resolverlo" en español. Go solo lo ejecuta y convierte su JSON a ErrorsReport.
//
// Se mantiene en PowerShell a propósito: Get-WinEvent y VersionInfo de los .sys
// ya están resueltos ahí (y es el mismo código probado del script), mientras que
// en Go implicaría WMI + parseo del recurso de versión PE.

//go:embed errores_windows.ps1
var scriptErrores []byte

var (
	scriptOnce sync.Once
	scriptPath string // ruta del .ps1 materializado; "" si no se pudo escribir
)

// Tiempo máximo del script: leer 30 días de registro de eventos y analizar los
// volcados puede tardar. Si se pasa, se devuelve el motivo en el reporte.
const timeoutErrores = 150 * time.Second

func collectErrors() ErrorsReport {
	rep := ErrorsReport{
		OS:       runtime.GOOS,
		Elevated: isElevated(),
		ScanDays: diasAnalisis,
		Source:   "Registro de eventos de Windows y volcados de memoria (.dmp)",
		Items:    []SystemError{},
		Dumps:    []DumpFile{},
	}

	ps1 := materializaScript()
	if ps1 == "" {
		rep.Reason = "No se pudo preparar el lector de eventos de Windows (no hay carpeta temporal escribible)."
		return rep
	}
	salida, err := os.CreateTemp("", "pcinfo-errores-*.json")
	if err != nil {
		rep.Reason = "No se pudo crear el archivo temporal de resultados: " + err.Error()
		return rep
	}
	salida.Close()
	defer os.Remove(salida.Name())

	if err := correPowerShell(ps1, salida.Name()); err != nil {
		warn("errores powershell", err)
		rep.Reason = "No se pudo leer el registro de eventos de Windows (" + err.Error() + "). " +
			"Verifica que el servicio 'Registro de eventos de Windows' esté en ejecución."
		return rep
	}

	datos, err := os.ReadFile(salida.Name())
	if err != nil || len(datos) == 0 {
		rep.Reason = "El lector de eventos no devolvió resultados."
		return rep
	}
	// PowerShell 5.1 escribe UTF-8 con BOM.
	datos = []byte(strings.TrimPrefix(string(datos), "\ufeff"))

	var crudo struct {
		OK       bool          `json:"ok"`
		Elevated bool          `json:"elevated"`
		Items    []SystemError `json:"items"`
		Dumps    []DumpFile    `json:"dumps"`
	}
	if err := json.Unmarshal(datos, &crudo); err != nil {
		warn("errores json", err)
		rep.Reason = "No se pudo interpretar la respuesta del lector de eventos: " + err.Error()
		return rep
	}

	rep.Available = true
	if crudo.Items != nil {
		rep.Items = crudo.Items
	}
	if crudo.Dumps != nil {
		rep.Dumps = crudo.Dumps
	}
	for i := range rep.Items {
		rep.Items[i].Detail = recorta(rep.Items[i].Detail, 4000)
	}
	// Sin permisos de administrador, el registro Security y algunos volcados no
	// se pueden leer: se avisa para que el usuario sepa que la lista puede estar
	// incompleta (no es un error, es un matiz).
	if !rep.Elevated {
		rep.Reason = "PCInfo no se está ejecutando como administrador: algunos volcados de memoria " +
			"(.dmp) y registros protegidos podrían no leerse. El resto del historial sí es completo."
	}
	return rep
}

// materializaScript escribe el .ps1 embebido en un temporal (una sola vez).
// IMPORTANTE: se escribe con BOM UTF-8 porque Windows PowerShell 5.1 interpreta
// los .ps1 SIN BOM como ANSI y destrozaría todos los acentos de los textos.
func materializaScript() string {
	scriptOnce.Do(func() {
		f, err := os.CreateTemp("", "pcinfo-errores-*.ps1")
		if err != nil {
			warn("errores script temp", err)
			return
		}
		if _, err := f.Write([]byte("\ufeff")); err != nil {
			warn("errores script bom", err)
			f.Close()
			return
		}
		if _, err := f.Write(scriptErrores); err != nil {
			warn("errores script write", err)
			f.Close()
			return
		}
		f.Close()
		scriptPath = f.Name()
	})
	return scriptPath
}

// correPowerShell ejecuta el script sin ventana de consola (el backend se compila
// con -H windowsgui: sin ocultaVentana aparecería una consola negra) y con
// timeout, igual que el resto de comandos externos del colector.
func correPowerShell(ps1, salida string) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeoutErrores)
	defer cancel()

	exe := rutaPowerShell()
	cmd := exec.CommandContext(ctx, exe,
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", ps1,
		"-Salida", salida,
		"-Dias", fmt.Sprint(diasAnalisis),
	)
	ocultaVentana(cmd)
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("la lectura del registro de eventos tardó demasiado")
	}
	if err != nil {
		return fmt.Errorf("%v: %s", err, recorta(string(out), 300))
	}
	return nil
}

func rutaPowerShell() string {
	if p, err := exec.LookPath("powershell.exe"); err == nil {
		return p
	}
	raiz := os.Getenv("SystemRoot")
	if raiz == "" {
		raiz = `C:\Windows`
	}
	return filepath.Join(raiz, `System32\WindowsPowerShell\v1.0\powershell.exe`)
}
