//go:build windows

package collector

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"golang.org/x/sys/windows/registry"
)

//go:embed software_windows.ps1
var scriptSoftware []byte

// Software instalado en Windows. Dos fuentes:
//
//  1. Programas clásicos: las claves "Uninstall" del registro — las mismas que
//     alimentan "Agregar o quitar programas". Se leen desde Go (rápido y sin
//     depender de PowerShell) en las TRES vistas: HKLM 64 bits, HKLM 32 bits
//     (WOW6432Node) y HKCU (lo instalado solo para este usuario, que es donde
//     viven Chrome, Teams o Zoom en muchos equipos).
//  2. Apps de la Tienda (Appx/MSIX): PowerShell, porque Get-AppxPackage resuelve
//     en una línea lo que en Go sería la API de empaquetado + el manifiesto.

// Tiempo máximo del script de apps de la Tienda: lee el manifiesto de cada
// paquete cuando el nombre bonito no está en el menú Inicio.
const timeoutAppx = 90 * time.Second

// Claves del registro donde Windows anota los programas instalados.
var clavesDesinstalar = []struct {
	raiz  registry.Key
	ruta  string
	quien string
	arch  string
}{
	{registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`, "todo el equipo", "64 bits"},
	{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`, "todo el equipo", "32 bits"},
	{registry.CURRENT_USER, `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`, "este usuario", ""},
	{registry.CURRENT_USER, `SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`, "este usuario", "32 bits"},
}

// Tipos de entrada que Windows marca como parche y no como programa.
var tiposActualizacion = map[string]bool{
	"security update": true,
	"update":          true,
	"hotfix":          true,
	"servicepack":     true,
}

var (
	// Parches: "Actualización de seguridad para Microsoft Office (KB1234567)".
	reParche = regexp.MustCompile(`(?i)\(KB\d{6,}\)|^KB\d{6,}\b|^(actualizaci[oó]n|update|hotfix|security update|service pack)\b`)
	// Runtimes y redistribuibles: están instalados pero nadie los eligió.
	reComponente = regexp.MustCompile(`(?i)\b(redistributable|redistribuible|runtime|\.NET (Framework|Core|Runtime)|Visual C\+\+|Windows SDK|Driver Package|paquete de controladores|MSI Tools|Update Health Tools|Kit de|Setup Bootstrapper)\b`)
	// Fecha de instalación tal como la guarda el registro: 20260723.
	reFechaRegistro = regexp.MustCompile(`^(\d{4})(\d{2})(\d{2})$`)
)

func collectSoftware() SoftwareReport {
	rep := SoftwareReport{
		OS:     "windows",
		Source: "Registro de Windows (programas instalados) y apps de la Tienda (Appx/MSIX)",
		Items:  []SoftwareItem{},
	}

	vistos := map[string]bool{}
	leidas := 0
	for _, c := range clavesDesinstalar {
		items, err := leeClaveDesinstalar(c.raiz, c.ruta, c.quien, c.arch)
		if err != nil {
			// Que falte una vista es normal (HKCU\WOW6432Node no siempre existe):
			// solo se registra, no se convierte en error del módulo.
			warn("software registro "+c.ruta, err)
			continue
		}
		leidas++
		for _, it := range items {
			clave := strings.ToLower(it.Name + "|" + it.Version)
			if vistos[clave] {
				continue
			}
			vistos[clave] = true
			rep.Items = append(rep.Items, it)
		}
	}
	if leidas > 0 {
		rep.Available = true
	} else {
		rep.Reason = "No se pudo leer el registro de programas instalados de Windows."
	}

	tienda, err := leeAppx()
	if err != nil {
		warn("software appx", err)
		rep.Reason = unir(rep.Reason,
			"No se pudieron listar las apps de la Tienda ("+err.Error()+"); "+
				"el resto de programas sí está completo.")
	} else {
		rep.Available = true
		rep.Items = append(rep.Items, tienda...)
	}
	return rep
}

// leeClaveDesinstalar recorre una de las vistas del registro y devuelve un
// SoftwareItem por subclave con nombre visible.
func leeClaveDesinstalar(raiz registry.Key, ruta, quien, arch string) ([]SoftwareItem, error) {
	k, err := registry.OpenKey(raiz, ruta, registry.ENUMERATE_SUB_KEYS|registry.QUERY_VALUE)
	if err != nil {
		return nil, err
	}
	defer k.Close()

	nombres, err := k.ReadSubKeyNames(-1)
	if err != nil {
		return nil, err
	}

	out := make([]SoftwareItem, 0, len(nombres))
	for _, sub := range nombres {
		s, err := registry.OpenKey(k, sub, registry.QUERY_VALUE)
		if err != nil {
			continue
		}
		nombre := limpiaTexto(cadena(s, "DisplayName"))
		if nombre == "" {
			s.Close()
			continue
		}
		it := SoftwareItem{
			Name:      nombre,
			Version:   limpiaTexto(cadena(s, "DisplayVersion")),
			Publisher: limpiaTexto(cadena(s, "Publisher")),
			Installed: fechaRegistro(cadena(s, "InstallDate")),
			Location:  limpiaTexto(cadena(s, "InstallLocation")),
			Uninstall: limpiaTexto(cadena(s, "UninstallString")),
			Arch:      arch,
			Source:    "Registro (" + quien + ")",
		}
		if kb, _, err := s.GetIntegerValue("EstimatedSize"); err == nil {
			it.SizeMB = int64(kb) / 1024 // el registro lo guarda en KiB
		}
		componente, _, _ := s.GetIntegerValue("SystemComponent")
		padre := limpiaTexto(cadena(s, "ParentKeyName"))
		tipo := strings.ToLower(limpiaTexto(cadena(s, "ReleaseType")))
		s.Close()

		clasificaPrograma(&it, componente == 1, padre != "", tipo, sub)
		out = append(out, it)
	}
	return out, nil
}

// clasificaPrograma decide qué es cada entrada del registro. Windows no lo dice
// en un solo campo, así que se combinan las pistas que sí existen: ReleaseType,
// SystemComponent, tener una entrada padre (típico de los parches) y el propio
// nombre.
func clasificaPrograma(it *SoftwareItem, componente, tienePadre bool, tipo, clave string) {
	switch {
	case tiposActualizacion[tipo] || tienePadre || reParche.MatchString(it.Name) || reParche.MatchString(clave):
		it.Kind = KindActualizacion
		it.System = true
	case componente || reComponente.MatchString(it.Name):
		it.Kind = KindComponente
		it.System = true
	default:
		it.Kind = KindPrograma
		it.System = false
	}
	it.Origin = OrigenUsuario
	if it.System {
		it.Origin = OrigenSistema
	}
}

// appxCrudo es lo que devuelve software_windows.ps1 por cada app de la Tienda.
type appxCrudo struct {
	Name          string `json:"name"`
	Version       string `json:"version"`
	Publisher     string `json:"publisher"`
	Arch          string `json:"arch"`
	Location      string `json:"location"`
	PackageName   string `json:"packageName"`
	SignatureKind string `json:"signatureKind"`
	IsFramework   bool   `json:"isFramework"`
	NonRemovable  bool   `json:"nonRemovable"`
}

// leeAppx lista las apps de la Tienda del usuario actual.
func leeAppx() ([]SoftwareItem, error) {
	salida, err := os.CreateTemp("", "pcinfo-software-*.json")
	if err != nil {
		return nil, err
	}
	salida.Close()
	defer os.Remove(salida.Name())

	if _, err := correPS("software", scriptSoftware, timeoutAppx, "-Salida", salida.Name()); err != nil {
		return nil, err
	}
	datos, err := os.ReadFile(salida.Name())
	if err != nil {
		return nil, err
	}
	if len(datos) == 0 {
		return nil, fmt.Errorf("el lector de apps de la Tienda no devolvió resultados")
	}
	datos = []byte(strings.TrimPrefix(string(datos), "\ufeff"))

	var crudos []appxCrudo
	if err := json.Unmarshal(datos, &crudos); err != nil {
		return nil, fmt.Errorf("respuesta ilegible: %w", err)
	}

	out := make([]SoftwareItem, 0, len(crudos))
	for _, c := range crudos {
		// Los "framework" son bibliotecas compartidas entre apps (VCLibs,
		// .NET Native): no son programas para el usuario.
		deSistema := c.IsFramework || c.NonRemovable ||
			strings.EqualFold(c.SignatureKind, "System")
		it := SoftwareItem{
			Name:      limpiaTexto(c.Name),
			Version:   limpiaTexto(c.Version),
			Publisher: limpiaTexto(c.Publisher),
			Location:  limpiaTexto(c.Location),
			Arch:      limpiaTexto(c.Arch),
			Source:    "Tienda (" + limpiaTexto(c.PackageName) + ")",
			Kind:      KindTienda,
			System:    deSistema,
			Origin:    OrigenUsuario,
		}
		if deSistema {
			it.Kind = KindComponente
			it.Origin = OrigenSistema
		}
		if it.Name == "" {
			continue
		}
		out = append(out, it)
	}
	return out, nil
}

// cadena lee un valor de texto del registro; "" si no existe o no es texto.
func cadena(k registry.Key, nombre string) string {
	v, _, err := k.GetStringValue(nombre)
	if err != nil {
		return ""
	}
	return v
}

// fechaRegistro convierte el "20260723" del registro a "2026-07-23".
func fechaRegistro(s string) string {
	s = strings.TrimSpace(s)
	if m := reFechaRegistro.FindStringSubmatch(s); m != nil {
		return m[1] + "-" + m[2] + "-" + m[3]
	}
	return ""
}

// unir concatena dos avisos sin dejar espacios sueltos si uno está vacío.
func unir(a, b string) string {
	switch {
	case a == "":
		return b
	case b == "":
		return a
	default:
		return a + " " + b
	}
}
