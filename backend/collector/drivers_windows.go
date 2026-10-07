//go:build windows

package collector

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

//go:embed drivers_windows.ps1
var scriptDrivers []byte

// Controladores y redes WiFi en Windows. Todo el trabajo lo hace el script de
// PowerShell embebido: Get-WindowsDriver / Export-WindowsDriver para los
// controladores, pnputil para instalarlos y netsh wlan para las redes.
//
// Por qué PowerShell y no Go: son las mismas herramientas que usaría un técnico
// a mano, ya resuelven la parte difícil (Export-WindowsDriver copia el .inf con
// TODOS sus archivos auxiliares) y su salida se puede leer línea a línea para
// mostrar el avance.

// Tiempo máximo del inventario. Get-WindowsDriver tarda unos segundos y la
// exportación temporal de las redes WiFi es inmediata.
const timeoutInventarioDrivers = 90 * time.Second

// inventarioCrudo es lo que devuelve drivers_windows.ps1 -Accion Listar. En
// Pendientes el script solo llena lo que sabe Windows; el estado redactado y el
// cruce con el catálogo se hacen aquí.
type inventarioCrudo struct {
	Elevated   bool                   `json:"elevated"`
	Reason     string                 `json:"reason"`
	Drivers    []DriverItem           `json:"drivers"`
	Wifi       []WifiProfile          `json:"wifi"`
	Pendientes []DispositivoPendiente `json:"pendientes"`
}

func estadoControladores() DriversReport {
	rep := DriversReport{
		OS:            "windows",
		Supported:     true,
		DriversAplica: true,
		Elevated:      isElevated(),
		Drivers:       []DriverItem{},
		Wifi:          []WifiProfile{},
		Pendientes:    []DispositivoPendiente{},
	}

	salida, err := os.CreateTemp("", "pcinfo-drivers-*.json")
	if err != nil {
		rep.Reason = "No se pudo crear el archivo temporal de resultados: " + err.Error()
		return rep
	}
	salida.Close()
	defer os.Remove(salida.Name())

	if _, err := correPS("drivers", scriptDrivers, timeoutInventarioDrivers,
		"-Accion", "Listar", "-Salida", salida.Name()); err != nil {
		warn("controladores listar", err)
		rep.Reason = "No se pudo leer el inventario de controladores y redes (" + err.Error() + ")."
		return rep
	}

	datos, err := os.ReadFile(salida.Name())
	if err != nil || len(datos) == 0 {
		rep.Reason = "El inventario de controladores no devolvió resultados."
		return rep
	}
	datos = []byte(strings.TrimPrefix(string(datos), "\ufeff"))

	var crudo inventarioCrudo
	if err := json.Unmarshal(datos, &crudo); err != nil {
		warn("controladores json", err)
		rep.Reason = "No se pudo interpretar el inventario de controladores: " + err.Error()
		return rep
	}

	rep.Available = true
	rep.Elevated = crudo.Elevated
	rep.Reason = crudo.Reason
	if crudo.Drivers != nil {
		rep.Drivers = crudo.Drivers
	}
	if crudo.Wifi != nil {
		rep.Wifi = crudo.Wifi
	}
	rep.Pendientes = explicaPendientes(crudo.Pendientes)
	rep.Web = candidatosWeb(rep.Pendientes, equipoActual())
	// Sin administrador netsh exporta los perfiles pero NO las contraseñas: se
	// avisa para que nadie crea que el respaldo servirá para restaurar.
	if !rep.Elevated && rep.Reason == "" {
		rep.Reason = "PCInfo no se está ejecutando como administrador: los controladores no se pueden " +
			"listar ni respaldar, y las redes WiFi salen sin contraseña."
	}
	return rep
}

func respaldaControladores(ctx context.Context, carpeta string) error {
	return tareaPS(ctx, "RespaldarDrivers", carpeta)
}

func restauraControladores(ctx context.Context, carpeta string) error {
	return tareaPS(ctx, "RestaurarDrivers", carpeta)
}

func respaldaWifi(ctx context.Context, carpeta string) error {
	return tareaPS(ctx, "RespaldarWifi", carpeta)
}

func restauraWifi(ctx context.Context, carpeta string) error {
	return tareaPS(ctx, "RestaurarWifi", carpeta)
}

// tareaPS ejecuta una acción del script y va publicando cada línea que imprime
// como un paso de la tarea. El prefijo de la línea (OK:, AVISO:, INFO:) decide
// el nivel con que la GUI la pinta.
func tareaPS(ctx context.Context, accion, carpeta string, extra ...string) error {
	var ultimo string
	err := correPSFlujo(ctx, "drivers", scriptDrivers, func(linea string) {
		nivel, texto := parteNivel(linea)
		ultimo = texto
		paso(nivel, texto)
	}, append([]string{"-Accion", accion, "-Carpeta", carpeta}, extra...)...)
	if err != nil {
		// PowerShell escribe el throw en stderr, que llega por el mismo canal:
		// la última línea suele ser el motivo real y es mucho más útil que el
		// "exit status 1" del proceso.
		if ultimo != "" {
			return fmt.Errorf("%s", ultimo)
		}
		return err
	}
	return nil
}

// parteNivel separa el prefijo de nivel de la línea del script.
func parteNivel(linea string) (string, string) {
	for prefijo, nivel := range map[string]string{
		"OK:":    PasoOK,
		"AVISO:": PasoAviso,
		"ERROR:": PasoError,
		"INFO:":  PasoInfo,
	} {
		if strings.HasPrefix(linea, prefijo) {
			return nivel, strings.TrimSpace(strings.TrimPrefix(linea, prefijo))
		}
	}
	return PasoInfo, linea
}
