//go:build windows

package collector

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
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
// PowerShell EMBEBIDO (errores_windows.ps1), hermano de herramientas/bluescreen/bluescreen.ps1:
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

var errTardoErrores = errors.New("la lectura del registro de eventos tardó demasiado")

// Al analizar una instalación apagada se mira MUCHO más atrás: un equipo que ya
// no arranca puede llevar semanas sin usarse, y con la ventana normal de 30 días
// el pantallazo que lo dejó muerto ya no aparecería.
const diasOffline = 180

func collectErrors(raizPedida string, limite int) ErrorsReport {
	rep := ErrorsReport{
		OS:       runtime.GOOS,
		Elevated: isElevated(),
		ScanDays: diasAnalisis,
		Limit:    limite,
		Source:   "Registro de eventos de Windows y volcados de memoria (.dmp)",
		Items:    []SystemError{},
		Dumps:    []DumpFile{},
		Installs: buscaInstalaciones(),
	}

	// Qué Windows se analiza: el que está corriendo (normal) o el de otra unidad
	// (equipo que no arranca, visto desde un medio de rescate tipo Hiren's).
	raiz, motivo := resuelveRaiz(raizPedida)
	rep.Target = raiz
	rep.Offline = !strings.EqualFold(raiz, systemRoot())
	rep.TargetLabel = etiquetaInstalacion(rep, raiz)
	if rep.Offline {
		rep.Source = "Registro de eventos y volcados de " + raiz + " (instalación que no está en ejecución)"
		rep.ScanDays = diasOffline
	}

	// Servicio "Registro de eventos de Windows" apagado o deshabilitado: se
	// intenta activarlo antes de leer (solo en el Windows en ejecución).
	if !rep.Offline {
		if aviso := aseguraServicioEventos(); aviso != "" {
			motivo = aviso
		}
		aseguraTareaBluescreen()
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

	if err := correPowerShell(ps1, salida.Name(), raiz, rep.ScanDays, limite); err != nil {
		warn("errores powershell", err)
		if rep.Offline {
			rep.Reason = "No se pudieron leer los registros de " + raiz + " (" + err.Error() + "). " +
				"Comprueba que la unidad sea accesible y ejecuta PCInfo como administrador."
		} else {
			if errors.Is(err, errTardoErrores) {
				rep.Reason = "La lectura del registro de eventos tardó demasiado y se canceló. " +
					"El registro es muy grande o el equipo está ocupado: reintenta con Refrescar."
			} else {
				rep.Reason = "No se pudo leer el registro de eventos de Windows (" + err.Error() + "). " +
					"Verifica que el servicio 'Registro de eventos de Windows' esté en ejecución."
			}
		}
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
		HasMore  bool          `json:"hasMore"`
	}
	if err := json.Unmarshal(datos, &crudo); err != nil {
		warn("errores json", err)
		rep.Reason = "No se pudo interpretar la respuesta del lector de eventos: " + err.Error()
		return rep
	}

	rep.Available = true
	rep.HasMore = crudo.HasMore
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
	switch {
	case motivo != "":
		rep.Reason = motivo
	case rep.Offline && !rep.Elevated:
		rep.Reason = "Se está leyendo una instalación de otra unidad sin permisos de administrador: " +
			"sus registros suelen estar protegidos y podrían faltar. Ejecuta PCInfo como administrador."
	case rep.Offline:
		rep.Reason = "Historial del Windows instalado en " + raiz + ", que NO es el que está corriendo. " +
			"Los mensajes originales pueden verse incompletos porque los textos los aporta el sistema apagado; " +
			"el diagnóstico (causa y solución) sí es válido."
	case !rep.Elevated:
		rep.Reason = "PCInfo no se está ejecutando como administrador: algunos volcados de memoria " +
			"(.dmp) y registros protegidos podrían no leerse. El resto del historial sí es completo."
	}
	return rep
}

// etiquetaInstalacion busca cómo llamar en pantalla a la raíz analizada.
func etiquetaInstalacion(rep ErrorsReport, raiz string) string {
	for _, in := range rep.Installs {
		if strings.EqualFold(in.Root, raiz) {
			return in.Titulo()
		}
	}
	if rep.Offline {
		return "Windows en " + raiz
	}
	return "Este equipo"
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
func correPowerShell(ps1, salida, raiz string, dias, limite int) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeoutErrores)
	defer cancel()

	exe := rutaPowerShell()
	cmd := exec.CommandContext(ctx, exe,
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", ps1,
		"-Salida", salida,
		"-Dias", fmt.Sprint(dias),
		"-MaxEventos", fmt.Sprint(limite),
		"-Raiz", raiz,
	)
	ocultaVentana(cmd)
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return errTardoErrores
	}
	if err != nil {
		return fmt.Errorf("%v: %s", err, recorta(string(out), 300))
	}
	return nil
}

// aseguraServicioEventos deja el servicio EventLog en inicio automático y en
// ejecución. Devuelve "" si ya estaba bien o se pudo arreglar, o un aviso en
// español si no se pudo (normalmente por falta de permisos de administrador).
func aseguraServicioEventos() string {
	sc := func(args ...string) string {
		cmd := exec.Command("sc.exe", args...)
		ocultaVentana(cmd)
		out, _ := cmd.CombinedOutput()
		return string(out)
	}
	if strings.Contains(sc("query", "EventLog"), "RUNNING") {
		return ""
	}
	if !isElevated() {
		return "El servicio 'Registro de eventos de Windows' no está en ejecución y PCInfo no puede " +
			"activarlo sin permisos de administrador. Reintenta como administrador."
	}
	sc("config", "EventLog", "start=", "auto")
	sc("start", "EventLog")
	for i := 0; i < 10; i++ {
		if strings.Contains(sc("query", "EventLog"), "RUNNING") {
			return "El servicio 'Registro de eventos de Windows' estaba apagado y PCInfo lo activó."
		}
		time.Sleep(time.Second)
	}
	return "El servicio 'Registro de eventos de Windows' está apagado y PCInfo no pudo activarlo; " +
		"actívalo desde services.msc."
}

// aseguraTareaBluescreen deja activa la tarea RecopilarBluescreens (la que
// anota cada pantallazo azul y garantiza el volcado). Si falta, la vuelve a
// instalar con el script empaquetado; si está deshabilitada, la habilita.
// Necesita administrador; sin él no hace nada (el aviso ya lo da el script).
func aseguraTareaBluescreen() {
	if !isElevated() {
		return
	}
	const tarea = "RecopilarBluescreens"
	schtasks := func(args ...string) (string, error) {
		cmd := exec.Command("schtasks.exe", args...)
		ocultaVentana(cmd)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	if out, err := schtasks("/query", "/tn", tarea, "/fo", "csv", "/nh"); err == nil {
		if strings.Contains(out, "Disabled") || strings.Contains(out, "Deshabilitad") {
			schtasks("/change", "/tn", tarea, "/enable")
		}
		return
	}
	exe, err := os.Executable()
	if err != nil {
		return
	}
	script := filepath.Join(filepath.Dir(exe), "bluescreen", "bluescreen.ps1")
	if _, err := os.Stat(script); err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, rutaPowerShell(), "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-File", script, "-InstalarTarea")
	ocultaVentana(cmd)
	if out, err := cmd.CombinedOutput(); err != nil {
		warn("bluescreen tarea", fmt.Errorf("%v: %s", err, recorta(string(out), 200)))
	}
}

func rutaPowerShell() string {
	if p, err := exec.LookPath("powershell.exe"); err == nil {
		return p
	}
	// Siempre el PowerShell del sistema EN EJECUCIÓN, nunca el de la instalación
	// analizada: el de un Windows apagado no se puede ejecutar.
	return filepath.Join(systemRoot(), `System32\WindowsPowerShell\v1.0\powershell.exe`)
}
