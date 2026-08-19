package collector

import (
	"context"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"time"
)

// Módulo "Software instalado": lista los programas del equipo con su versión.
//
// Contrato: GET /software → SoftwareReport. Espejo en
// pcinfo/lib/models/software.dart.
//
// Windows: registro de Desinstalar (HKLM 64 y 32 bits + HKCU) y apps de la
// Tienda (Appx/MSIX). Linux: dpkg / rpm + flatpak + snap.
//
// Decisión: el backend devuelve TODO lo que encuentra y MARCA cada elemento
// (Kind + System); filtrar es cosa de la GUI. Así el interruptor "mostrar
// componentes del sistema" no obliga a volver a preguntar al backend, y nunca
// se pierde un dato por un filtro demasiado agresivo del colector.

// Clasificación de un programa (campo Kind).
const (
	KindPrograma      = "programa"      // instalado normal (Agregar o quitar programas / paquete)
	KindTienda        = "tienda"        // app de la Tienda (Appx/MSIX), flatpak o snap
	KindActualizacion = "actualizacion" // parche, KB, service pack
	KindComponente    = "componente"    // runtime/redistribuible/componente del sistema
)

// Origen del programa: quién lo puso ahí. Es el criterio con el que se agrupa la
// exportación a .md ("lo que trae el sistema" vs "lo que instaló el usuario").
//
// Cómo se decide, porque no hay un dato oficial que lo diga:
//   - Windows: actualizaciones y componentes del sistema, y las apps de la
//     Tienda firmadas como System (las que vienen en la imagen de Windows) →
//     sistema. Todo lo que aparece en "Agregar o quitar programas" y no es un
//     parche ni un redistribuible → usuario, aunque el fabricante sea Microsoft
//     (Office o Edge los instaló alguien).
//   - Linux: los paquetes que apt marca como "manual" (apt-mark showmanual), más
//     flatpak y snap → usuario; las dependencias y el resto de la distribución →
//     sistema.
const (
	OrigenSistema = "sistema"
	OrigenUsuario = "usuario"
)

// Tiempo máximo de cada herramienta externa consultada (PowerShell, dpkg, rpm…).
const timeoutSoftware = 60 * time.Second

// SoftwareItem es UN programa instalado.
type SoftwareItem struct {
	Name      string `json:"name"`      // nombre visible
	Version   string `json:"version"`   // versión tal cual la declara el instalador
	Publisher string `json:"publisher"` // fabricante
	Installed string `json:"installed"` // fecha de instalación "2026-07-23" (si se sabe)
	SizeMB    int64  `json:"sizeMB"`    // tamaño aproximado en MiB (0 = desconocido)
	Location  string `json:"location"`  // carpeta de instalación (si se sabe)
	Arch      string `json:"arch"`      // 64 bits | 32 bits | x64/arm64 (Tienda)
	Source    string `json:"source"`    // de dónde salió el dato (registro, dpkg, flatpak…)
	Kind      string `json:"kind"`      // ver constantes Kind*
	System    bool   `json:"system"`    // componente/actualización del sistema (oculto por defecto)
	Origin    string `json:"origin"`    // sistema | usuario (ver constantes Origen*)
	Uninstall string `json:"uninstall"` // comando de desinstalación declarado (informativo)
}

// SoftwareReport es la respuesta de GET /software.
type SoftwareReport struct {
	OS        string         `json:"os"`        // windows | linux
	Source    string         `json:"source"`    // fuentes consultadas, en español
	Available bool           `json:"available"` // ¿se pudo leer alguna fuente?
	Reason    string         `json:"reason"`    // aviso cuando algo no se pudo leer
	Total     int            `json:"total"`     // total encontrado (incluye los del sistema)
	Visible   int            `json:"visible"`   // los que la GUI muestra por defecto
	Items     []SoftwareItem `json:"items"`
}

// CollectSoftware arma el inventario de software del sistema en ejecución.
func CollectSoftware() SoftwareReport {
	rep := safe("software", collectSoftware)
	if rep.Items == nil {
		rep.Items = []SoftwareItem{}
	}
	if rep.OS == "" {
		rep.OS = runtime.GOOS
	}
	ordenaSoftware(rep.Items)
	rep.Total = len(rep.Items)
	rep.Visible = 0
	for i := range rep.Items {
		if rep.Items[i].Origin == "" {
			rep.Items[i].Origin = OrigenUsuario
			if rep.Items[i].System {
				rep.Items[i].Origin = OrigenSistema
			}
		}
		if !rep.Items[i].System {
			rep.Visible++
		}
	}
	return rep
}

// ordenaSoftware deja la lista alfabética ignorando mayúsculas, que es como el
// usuario espera buscar a ojo.
func ordenaSoftware(items []SoftwareItem) {
	sort.SliceStable(items, func(i, j int) bool {
		a, b := strings.ToLower(items[i].Name), strings.ToLower(items[j].Name)
		if a == b {
			return items[i].Version < items[j].Version
		}
		return a < b
	})
}

// ejecuta corre un comando externo con timeout y sin ventana de consola.
func ejecuta(nombre string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeoutSoftware)
	defer cancel()
	cmd := exec.CommandContext(ctx, nombre, args...)
	ocultaVentana(cmd)
	out, err := cmd.Output()
	return string(out), err
}

// limpiaTexto normaliza un valor leído del registro o de un comando.
func limpiaTexto(s string) string {
	s = strings.TrimSpace(strings.ReplaceAll(s, "\x00", ""))
	return strings.Join(strings.Fields(s), " ")
}
