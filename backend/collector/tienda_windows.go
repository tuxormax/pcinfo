//go:build windows

package collector

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/windows"
)

//go:embed tienda_windows.ps1
var scriptTiendaBase []byte

//go:embed tienda_win10.ps1
var scriptTiendaWin10 []byte

//go:embed tienda_win11.ps1
var scriptTiendaWin11 []byte

//go:embed tienda_acciones.ps1
var scriptTiendaAcciones []byte

// Windows 11 empieza en la build 22000. Cada versión tiene su fragmento
// (Preparar-Instalacion): W10 activa el sideloading (LTSC no trae la Tienda),
// W11 no toca nada.
const buildWin11 = 22000

// scriptTienda arma el script: base común + fragmento de la versión + acciones.
var scriptTienda = func() []byte {
	frag := scriptTiendaWin10
	if v := windows.RtlGetVersion(); v != nil && v.BuildNumber >= buildWin11 {
		frag = scriptTiendaWin11
	}
	var b []byte
	for _, parte := range [][]byte{scriptTiendaBase, frag, scriptTiendaAcciones} {
		b = append(b, parte...)
		b = append(b, '\n')
	}
	return b
}()

// Instalación de apps de la Microsoft Store en Windows. Todo el trabajo lo
// hace el script de PowerShell embebido (ver tienda_windows.ps1): resuelve
// los enlaces de descarga contra store.rg-adguard.net e instala con
// Add-AppxPackage/Add-AppxProvisionedPackage.

const timeoutBusqueda = 25 * time.Second

func estadoTienda() TiendaInfo {
	return TiendaInfo{
		OS:        "windows",
		Supported: true,
		Elevated:  isElevated(),
		Catalogo:  CatalogoTienda,
	}
}

func buscaTienda(consulta string) ([]AppTienda, error) {
	salida, err := os.CreateTemp("", "pcinfo-tienda-buscar-*.json")
	if err != nil {
		return nil, fmt.Errorf("no se pudo crear el archivo temporal de resultados: %w", err)
	}
	salida.Close()
	defer os.Remove(salida.Name())

	if _, err := correPS("tienda", scriptTienda, timeoutBusqueda,
		"-Accion", "Buscar", "-Consulta", consulta, "-Salida", salida.Name()); err != nil {
		return nil, fmt.Errorf("no se pudo buscar en la Store: %w", err)
	}

	datos, err := os.ReadFile(salida.Name())
	if err != nil || len(datos) == 0 {
		return nil, fmt.Errorf("la búsqueda no devolvió resultados")
	}
	datos = []byte(strings.TrimPrefix(string(datos), "\ufeff"))

	var apps []AppTienda
	if err := json.Unmarshal(datos, &apps); err != nil {
		return nil, fmt.Errorf("no se pudo interpretar la respuesta de la Store: %w", err)
	}
	if apps == nil {
		apps = []AppTienda{}
	}
	return apps, nil
}

func instalaApps(ctx context.Context, apps []AppTienda, arch, ring string, todos bool) error {
	f, err := os.CreateTemp("", "pcinfo-tienda-apps-*.json")
	if err != nil {
		return fmt.Errorf("no se pudo preparar la lista de apps: %w", err)
	}
	defer os.Remove(f.Name())
	if err := json.NewEncoder(f).Encode(apps); err != nil {
		f.Close()
		return fmt.Errorf("no se pudo preparar la lista de apps: %w", err)
	}
	f.Close()

	return correTareaTiendaPS(ctx,
		"-Accion", "Instalar",
		"-AppsArchivo", f.Name(),
		"-Arch", argOrAuto(arch),
		"-Ring", argOrDefault(ring, "Retail"),
		"-Todos", strconv.FormatBool(todos),
	)
}

func instalaCarpeta(ctx context.Context, carpeta, arch string, todos bool) error {
	return correTareaTiendaPS(ctx,
		"-Accion", "InstalarCarpeta",
		"-Carpeta", carpeta,
		"-Arch", argOrAuto(arch),
		"-Todos", strconv.FormatBool(todos),
	)
}

// correTareaTiendaPS ejecuta el script publicando cada línea como un paso de
// la tarea. Mismo prefijo de nivel que Controladores (OK:, AVISO:, ERROR:,
// INFO:) — parteNivel() ya sabe leerlo.
func correTareaTiendaPS(ctx context.Context, args ...string) error {
	var ultimo string
	err := correPSFlujo(ctx, "tienda", scriptTienda, func(linea string) {
		nivel, texto := parteNivel(linea)
		ultimo = texto
		pasoTienda(nivel, texto)
	}, args...)
	if err != nil {
		if ultimo != "" {
			return fmt.Errorf("%s", ultimo)
		}
		return err
	}
	return nil
}

func argOrAuto(v string) string { return argOrDefault(v, "Auto") }

func argOrDefault(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return v
}
