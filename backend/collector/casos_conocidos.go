package collector

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
)

// Catálogo de casos conocidos: dispositivos que en un equipo bien atendido
// aparecen SIN controlador, con el genérico de Windows o deshabilitados A
// PROPÓSITO, y por qué.
//
// Para qué sirve: el Administrador de dispositivos —y la propia pestaña de
// PCInfo— enseñan un triángulo amarillo y un "sin controlador" que asusta al
// usuario meses después de que un técnico dejara ese dispositivo así a
// conciencia. Aquí se guarda la explicación en llano para ponerla al lado.
//
// De dónde sale el contenido: es una COPIA REDUCIDA Y VERIFICADA de la tabla
// $CATALOGO del proyecto hermano `windows/arreglador` (cada fila dice de qué
// entrada viene). No se comparte el archivo entre los dos repos a propósito:
// son repos distintos que deben compilar solos, el catálogo del arreglador es
// código PowerShell y no datos, y la mitad de sus campos (Receta, Herramienta,
// Snappy) solo le sirven a una herramienta que INSTALA cosas. PCInfo no instala
// nada: solo necesita el patrón de hardware, qué es el aparato y el motivo.
//
// Solo se copian las entradas que se reconocen por ID DE HARDWARE (el
// `Buscar.Id` del arreglador), porque es lo único que PCInfo enumera y es la
// vía que NO depende del idioma de Windows. Las que el arreglador reconoce por
// servicio, archivo .sys o programa instalado (Intel RST, Nahimic, SupportAssist…)
// quedan fuera de esta versión.
//
// Igual que el catálogo de placas: va embebido (funciona sin internet, que es
// el caso normal en un taller) y se refresca desde el repo en segundo plano,
// así que corregir un texto y subirlo alcanza a las instalaciones ya hechas.

//go:embed controladores_conocidos.json
var casosEmbebidos []byte

const (
	archivoCasos = "controladores_conocidos.json"
	urlCasos     = "https://raw.githubusercontent.com/tuxormax/pcinfo/main/backend/collector/" + archivoCasos
)

// Vías del catálogo: qué se hace con ese componente.
const (
	ViaQuitar     = "quitar"     // no se le pone controlador: se quita o se deshabilita
	ViaGenerico   = "generico"   // se deja el controlador de Microsoft a propósito
	ViaFabricante = "fabricante" // hace falta uno concreto del fabricante
)

// CasoConocido es una fila del catálogo.
type CasoConocido struct {
	ID          string `json:"id"`          // slug, el mismo que usa el arreglador
	Nombre      string `json:"nombre"`      // "Intel DPTF / Dynamic Tuning"
	Descripcion string `json:"descripcion"` // qué ES el aparato, en llano
	BuscarID    string `json:"buscarId"`    // patrón contra el ID de hardware
	Via         string `json:"via"`         // quitar | generico | fabricante
	Motivo      string `json:"motivo"`      // por qué está así, para el usuario
	Fuente      string `json:"fuente"`      // de qué entrada del arreglador viene

	re *regexp.Regexp
}

var (
	casosUnaVez sync.Once
	casos       []CasoConocido
)

func cargaCasos() {
	casos = compilaCasos(casosEmbebidos)
	if b, err := os.ReadFile(rutaCache(archivoCasos)); err == nil {
		if c := compilaCasos(b); len(c) > 0 {
			casos = c // la versión descargada pisa a la embebida
		}
	}
	go refrescaArchivo(urlCasos, rutaCache(archivoCasos), casosValidos)
}

// compilaCasos lee el JSON y deja compilado el patrón de cada fila. Una fila con
// un patrón inválido se descarta sola: el catálogo es una mejora, nunca un
// motivo de fallo.
func compilaCasos(b []byte) []CasoConocido {
	var lista []CasoConocido
	if err := json.Unmarshal(b, &lista); err != nil {
		warn("catálogo de casos conocidos", err)
		return nil
	}
	fuera := lista[:0]
	for _, c := range lista {
		if c.ID == "" || c.BuscarID == "" {
			continue
		}
		re, err := regexp.Compile("(?i)" + c.BuscarID)
		if err != nil {
			warn("caso conocido "+c.ID, err)
			continue
		}
		c.re = re
		fuera = append(fuera, c)
	}
	return fuera
}

func casosValidos(b []byte) bool { return len(compilaCasos(b)) > 0 }

// explicaDispositivo busca el caso conocido que coincide con los identificadores
// de hardware de un dispositivo (su InstanceId y sus HardwareIDs, tal como los
// da Windows).
//
// Gana el PRIMERO del archivo: hay patrones que se solapan a propósito
// —INT3400 es el DPTF y además cae dentro del rango INT34xx del Serial IO— y el
// orden del catálogo es el desempate.
func explicaDispositivo(ids ...string) *CasoConocido {
	casosUnaVez.Do(cargaCasos)
	texto := strings.Join(ids, " ")
	if strings.TrimSpace(texto) == "" {
		return nil
	}
	for i := range casos {
		if casos[i].re.MatchString(texto) {
			c := casos[i]
			return &c
		}
	}
	return nil
}

// explicaPendientes redacta el estado de cada dispositivo con problema y le
// pega la explicación del catálogo cuando la hay.
//
// Los reconocidos van PRIMERO: son los que tienen algo que contar, y son los
// que el usuario vino a entender. El resto queda debajo, en orden alfabético.
func explicaPendientes(lista []DispositivoPendiente) []DispositivoPendiente {
	fuera := make([]DispositivoPendiente, 0, len(lista))
	for _, d := range lista {
		d.Conocido = explicaDispositivo(d.InstanceID, d.HardwareID)
		d.Estado = textoCodigoPnP(d.Codigo)
		if d.Nombre == "" {
			d.Nombre = "Dispositivo desconocido"
		}
		// Del arreglo de IDs de hardware solo se enseña el primero: es el más
		// específico (el modelo exacto) y los demás solo lo van generalizando.
		d.HardwareID = primerID(d.HardwareID)
		fuera = append(fuera, d)
	}
	sort.SliceStable(fuera, func(i, j int) bool {
		a, b := fuera[i].Conocido != nil, fuera[j].Conocido != nil
		if a != b {
			return a
		}
		return strings.ToLower(fuera[i].Nombre) < strings.ToLower(fuera[j].Nombre)
	})
	return fuera
}

func primerID(s string) string {
	if campos := strings.Fields(s); len(campos) > 0 {
		return campos[0]
	}
	return ""
}

// textoCodigoPnP traduce el código de problema que Windows le pone a un
// dispositivo (ConfigManagerErrorCode) a una frase que se entienda. Son los
// mismos códigos que el Administrador de dispositivos enseña como "Código 28".
func textoCodigoPnP(codigo int) string {
	switch codigo {
	case 1:
		return "Windows no tiene bien configurado este dispositivo."
	case 10:
		return "El dispositivo no puede iniciarse."
	case 12:
		return "No hay recursos libres suficientes para que funcione."
	case 14:
		return "Hace falta reiniciar el equipo para que funcione."
	case 18:
		return "Hay que volver a instalar su controlador."
	case 19:
		return "Su información en el registro de Windows está dañada."
	case 21:
		return "Windows lo está quitando."
	case 22:
		return "Está deshabilitado."
	case 24:
		return "No está presente, no funciona bien o le faltan controladores."
	case 28:
		return "No tiene controlador instalado."
	case 31:
		return "Windows no puede cargar su controlador."
	case 43:
		return "Windows lo detuvo porque informó de un problema."
	case 45:
		return "No está conectado al equipo en este momento."
	default:
		return fmt.Sprintf("Windows lo marca con el código de problema %d.", codigo)
	}
}
