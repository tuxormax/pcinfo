package collector

import (
	"runtime"
	"sort"
	"strings"
)

// Módulo "Errores del sistema": lee los registros del SISTEMA OPERATIVO
// (pantallazos azules y registro de eventos en Windows, journald / kernel en
// Linux) y los devuelve YA INTERPRETADOS: qué pasó, quién lo causó y cómo se
// resuelve, en español. Es el equivalente multiplataforma del script
// www/windows/bluescreen.ps1 (de ahí vienen el catálogo de STOP codes, el
// análisis del .dmp y la deducción del driver culpable).
//
// Contrato: GET /errores → ErrorsReport. Espejo en pcinfo/lib/models/errores.dart.

// Días de historial que se analizan (los eventos más viejos se descartan).
const diasAnalisis = 30

// Tope de eventos devueltos a la GUI (ya agrupados). Evita respuestas enormes
// en equipos con registros muy sucios.
const maxErrores = 300

// Clasificación de un error (campo Kind). La GUI filtra por estas categorías.
const (
	KindBSOD     = "pantallazo" // pantalla azul / kernel panic
	KindApagado  = "apagado"    // apagado o reinicio inesperado
	KindHardware = "hardware"   // WHEA/MCE, RAM, CPU, temperatura, PCIe
	KindDisco    = "disco"      // disco, sistema de archivos, controladora
	KindGrafica  = "grafica"    // driver de video (TDR, Xid, GPU reset)
	KindServicio = "servicio"   // servicio/unidad que no arranca o muere
	KindApp      = "aplicacion" // programa que se cierra o se cuelga
	KindMemoria  = "memoria"    // sin memoria (OOM)
	KindSistema  = "sistema"    // resto del sistema operativo
)

// Severidad (campo Severity).
const (
	SevCritico = "critico"
	SevError   = "error"
	SevAviso   = "aviso"
)

// SystemError es UN problema del sistema operativo ya interpretado. Los eventos
// repetidos se agrupan en un solo elemento con Count > 1 (First/When = rango).
type SystemError struct {
	ID        string `json:"id"`        // identificador estable (fuente + evento)
	When      string `json:"when"`      // última vez, hora local "2026-07-23 14:02:11"
	FirstWhen string `json:"firstWhen"` // primera vez (si Count > 1)
	Count     int    `json:"count"`     // veces que se repitió
	Severity  string `json:"severity"`  // critico | error | aviso
	Kind      string `json:"kind"`      // ver constantes Kind*
	Title     string `json:"title"`     // qué pasó, en una línea
	Source    string `json:"source"`    // de dónde salió (evento, unidad, kernel)
	Code      string `json:"code"`      // STOP code / id de evento / señal
	CodeName  string `json:"codeName"`  // nombre del STOP code

	// Culpable deducido (Windows: driver del .dmp; Linux: proceso/módulo).
	Culprit     string   `json:"culprit"`
	CulpritInfo string   `json:"culpritInfo"` // fabricante, versión y ruta
	Confidence  string   `json:"confidence"`  // alta | media | baja
	Suspects    []string `json:"suspects"`    // otros sospechosos

	Cause  string `json:"cause"`  // por qué ocurre (español)
	Fix    string `json:"fix"`    // cómo resolverlo (español)
	Detail string `json:"detail"` // texto crudo del registro
}

// DumpFile es un volcado de memoria presente en el disco (Windows: minidumps y
// MEMORY.DMP; Linux: coredumps/apport). Sirve para llevárselos a analizar.
type DumpFile struct {
	Path      string `json:"path"`
	When      string `json:"when"`
	SizeBytes int64  `json:"sizeBytes"`
}

// ErrorsReport es la raíz del JSON de GET /errores.
type ErrorsReport struct {
	OS        string        `json:"os"`        // "windows" | "linux"
	Elevated  bool          `json:"elevated"`  // ¿el backend corre como admin/root?
	Source    string        `json:"source"`    // fuente consultada (para mostrar)
	Available bool          `json:"available"` // ¿se pudo leer alguna fuente?
	Reason    string        `json:"reason"`    // si no, por qué (accionable)
	ScanDays  int           `json:"scanDays"`  // días de historial analizados
	Items     []SystemError `json:"items"`
	Dumps     []DumpFile    `json:"dumps"`
}

// CollectErrors arma el reporte de errores del sistema. Igual que Collect(), va
// envuelto en safe(): si la lectura de registros entra en pánico devuelve un
// reporte vacío en vez de tumbar el endpoint.
func CollectErrors() ErrorsReport {
	rep := safe("errores", collectErrors)
	if rep.OS == "" {
		rep.OS = runtime.GOOS
	}
	if rep.ScanDays == 0 {
		rep.ScanDays = diasAnalisis
	}
	if rep.Items == nil {
		rep.Items = []SystemError{}
	}
	if rep.Dumps == nil {
		rep.Dumps = []DumpFile{}
	}
	ordenaErrores(rep.Items)
	if len(rep.Items) > maxErrores {
		rep.Items = rep.Items[:maxErrores]
	}
	return rep
}

// ordenaErrores deja primero lo más grave y, dentro de la misma gravedad, lo más
// reciente: un pantallazo de hace un mes importa más que un aviso de hoy.
func ordenaErrores(items []SystemError) {
	sort.SliceStable(items, func(i, j int) bool {
		a, b := items[i], items[j]
		if pesoSeveridad(a) != pesoSeveridad(b) {
			return pesoSeveridad(a) > pesoSeveridad(b)
		}
		return a.When > b.When // formato "YYYY-MM-DD HH:MM:SS" ordena como texto
	})
}

func pesoSeveridad(e SystemError) int {
	// El pantallazo/panic siempre manda, aunque su severidad sea la misma.
	if e.Kind == KindBSOD {
		return 4
	}
	switch e.Severity {
	case SevCritico:
		return 3
	case SevError:
		return 2
	default:
		return 1
	}
}

// recorta deja un texto crudo en un tamaño razonable para la GUI.
func recorta(s string, max int) string {
	s = strings.TrimSpace(s)
	if len(s) <= max {
		return s
	}
	return s[:max] + "…"
}
