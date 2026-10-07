package collector

import (
	_ "embed"
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"sync"
)

// Catálogo de controladores DESCARGABLES del fabricante.
//
// Para qué sirve: un dispositivo con "Código 28" (sin controlador) se puede
// resolver bajando el paquete oficial del fabricante. Se descarta Windows Update
// a propósito (decisión de tuxor, 7-oct-2026): en los equipos que atiende suele
// estar desactivado, así que la fuente es este catálogo propio con enlaces
// directos a Intel, AMD, NVIDIA, Realtek…
//
// Igual que los otros catálogos: va embebido (funciona sin internet) y se
// refresca desde el repo, así que añadir o corregir un enlace alcanza a las
// instalaciones ya hechas sin reinstalar.
//
// ⛔ SEGURIDAD: el catálogo se refresca por internet y lo que describe se
// EJECUTA como administrador. Por eso una fila sin `sha256` o sin `https://` se
// descarta al compilar, y en Windows los .exe/.msi además deben traer firma
// Authenticode válida (drivers_windows.ps1 → InstalarWeb). El hash fija la
// versión exacta: si el fabricante cambia el archivo, la fila deja de instalar
// hasta que se actualice (mejor eso que ejecutar algo no revisado).

//go:embed catalogo_drivers.json
var driversWebEmbebidos []byte

const (
	archivoDriversWeb = "catalogo_drivers.json"
	urlDriversWeb     = "https://raw.githubusercontent.com/tuxormax/pcinfo/main/backend/collector/" + archivoDriversWeb
)

// Tipos de paquete que sabe instalar PCInfo.
const (
	PaqueteZip = "zip" // .zip con .inf → pnputil
	PaqueteExe = "exe" // instalador del fabricante con argumentos silenciosos
	PaqueteMsi = "msi" // msiexec /i … /qn
)

// DriverWeb es una fila del catálogo.
type DriverWeb struct {
	ID         string `json:"id"`
	Nombre     string `json:"nombre"`     // "Realtek PCIe GbE Family Controller"
	Fabricante string `json:"fabricante"` // quien lo publica
	BuscarID   string `json:"buscarId"`   // patrón contra el ID de hardware
	// Equipo (opcional) limita la fila a un equipo concreto: patrón contra
	// «Fabricante Modelo» de la máquina ("HP Elite SFF 805 G9"). Los paquetes de
	// HP, Dell, Lenovo, Acer o ASUS son POR MODELO; sin este filtro se ofrecerían
	// en cualquier equipo que comparta el chip. Vacío = vale para cualquiera.
	Equipo  string `json:"equipo"`
	URL     string `json:"url"`    // enlace directo, https
	SHA256  string `json:"sha256"` // del archivo descargado, 64 hex
	Tipo    string `json:"tipo"`   // zip | exe | msi
	Args    string `json:"args"`   // argumentos silenciosos (solo exe/msi)
	Version string `json:"version"`
	Nota    string `json:"nota"` // aviso para quien lo instala (opcional)

	// Herramienta del fabricante (HP Image Assistant, Dell Command | Update,
	// Lenovo Thin Installer…): en vez de un controlador suelto, se instala la
	// herramienta oficial y luego se EJECUTA, y ella busca y baja los
	// controladores del modelo exacto. Es lo que permite cubrir una marca sin
	// conocer los modelos. Estas filas no llevan BuscarID: se ofrecen cuando
	// Equipo coincide (que entonces es obligatorio).
	Ejecuta     string `json:"ejecuta"`     // ruta del programa ya instalado (admite %ProgramFiles%…)
	EjecutaArgs string `json:"ejecutaArgs"` // sus argumentos
	// Exitos: códigos de salida que cuentan como «bien», tanto del instalador como
	// de la herramienta. Vacío = 0 y 3010 (éxito y «pide reiniciar»).
	Exitos []int `json:"exitos"`

	re       *regexp.Regexp
	reEquipo *regexp.Regexp
}

var sha256Hex = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)

var (
	driversWebUnaVez sync.Once
	driversWeb       []DriverWeb
)

func cargaDriversWeb() {
	driversWeb = compilaDriversWeb(driversWebEmbebidos)
	if b, err := os.ReadFile(rutaCache(archivoDriversWeb)); err == nil {
		if c := compilaDriversWeb(b); c != nil {
			driversWeb = c
		}
	}
	go refrescaArchivo(urlDriversWeb, rutaCache(archivoDriversWeb), func(b []byte) bool {
		return compilaDriversWeb(b) != nil
	})
}

// compilaDriversWeb lee el JSON y descarta las filas inseguras o mal formadas.
// Devuelve nil si el JSON no es válido; una lista vacía (no nil) si es válido
// pero sin filas, que es el estado inicial legítimo del catálogo.
func compilaDriversWeb(b []byte) []DriverWeb {
	var lista []DriverWeb
	if err := json.Unmarshal(b, &lista); err != nil {
		warn("catálogo de controladores web", err)
		return nil
	}
	fuera := []DriverWeb{}
	for _, d := range lista {
		if d.ID == "" || d.Nombre == "" {
			continue
		}
		// Un controlador suelto se reconoce por ID de hardware; una herramienta del
		// fabricante, por el equipo (sin eso se ofrecería en cualquier marca).
		if d.Ejecuta == "" && d.BuscarID == "" || d.Ejecuta != "" && d.Equipo == "" {
			continue
		}
		if !strings.HasPrefix(strings.ToLower(d.URL), "https://") || !sha256Hex.MatchString(d.SHA256) {
			continue
		}
		if d.Tipo != PaqueteZip && d.Tipo != PaqueteExe && d.Tipo != PaqueteMsi {
			continue
		}
		if d.BuscarID != "" {
			re, err := regexp.Compile("(?i)" + d.BuscarID)
			if err != nil {
				warn("controlador web "+d.ID, err)
				continue
			}
			d.re = re
		}
		if d.Equipo != "" {
			var err error
			if d.reEquipo, err = regexp.Compile("(?i)" + d.Equipo); err != nil {
				warn("controlador web "+d.ID+" (equipo)", err)
				continue
			}
		}
		d.SHA256 = strings.ToLower(d.SHA256)
		fuera = append(fuera, d)
	}
	return fuera
}

// driverWebPorID devuelve la fila del catálogo con ese id. La descarga SIEMPRE
// se resuelve aquí y nunca con una URL que mande la GUI.
func driverWebPorID(id string) (DriverWeb, bool) {
	driversWebUnaVez.Do(cargaDriversWeb)
	for _, d := range driversWeb {
		if d.ID == id {
			return d, true
		}
	}
	return DriverWeb{}, false
}

// CandidatoWeb es un controlador del catálogo que corresponde a un dispositivo
// del equipo que está sin controlador.
type CandidatoWeb struct {
	ID          string `json:"id"`          // fila del catálogo
	Dispositivo string `json:"dispositivo"` // como lo llama Windows
	InstanceID  string `json:"instanceId"`
	Nombre      string `json:"nombre"`
	Fabricante  string `json:"fabricante"`
	Version     string `json:"version"`
	Tipo        string `json:"tipo"`
	Nota        string `json:"nota"`
	// Recomendado=false cuando el catálogo de casos conocidos dice que ese
	// dispositivo se deja sin controlador A PROPÓSITO: sale en la lista, desmarcado
	// y con el motivo en Aviso.
	Recomendado bool   `json:"recomendado"`
	Aviso       string `json:"aviso"`
}

// candidatosWeb cruza los dispositivos pendientes con el catálogo. Un mismo
// dispositivo y una misma fila salen una sola vez.
func candidatosWeb(pend []DispositivoPendiente, equipo string) []CandidatoWeb {
	driversWebUnaVez.Do(cargaDriversWeb)
	fuera := []CandidatoWeb{}
	visto := map[string]bool{}
	// Herramientas del fabricante: no dependen de ningún dispositivo pendiente.
	for _, d := range driversWeb {
		if d.Ejecuta != "" && d.reEquipo.MatchString(equipo) {
			fuera = append(fuera, CandidatoWeb{
				ID: d.ID, Dispositivo: "Todo el equipo (" + equipo + ")", Nombre: d.Nombre,
				Fabricante: d.Fabricante, Version: d.Version, Tipo: d.Tipo, Nota: d.Nota,
				Recomendado: true,
			})
		}
	}
	for _, p := range pend {
		texto := p.InstanceID + " " + p.HardwareID
		for _, d := range driversWeb {
			if d.re == nil {
				continue // herramienta del fabricante: ya salió arriba
			}
			if d.reEquipo != nil && !d.reEquipo.MatchString(equipo) {
				continue
			}
			if !d.re.MatchString(texto) || visto[d.ID+"|"+p.InstanceID] {
				continue
			}
			visto[d.ID+"|"+p.InstanceID] = true
			c := CandidatoWeb{
				ID: d.ID, Dispositivo: p.Nombre, InstanceID: p.InstanceID,
				Nombre: d.Nombre, Fabricante: d.Fabricante, Version: d.Version,
				Tipo: d.Tipo, Nota: d.Nota, Recomendado: true,
			}
			if p.Conocido != nil && p.Conocido.Via != ViaFabricante {
				c.Recomendado = false
				c.Aviso = "Se dejó así a propósito: " + p.Conocido.Motivo
			}
			fuera = append(fuera, c)
			break // una fila por dispositivo: gana la primera del archivo
		}
	}
	return fuera
}
