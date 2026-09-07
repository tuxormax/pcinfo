package collector

import (
	"runtime"
	"strconv"
	"strings"
)

// Módulo "Encendidos y apagados": responde a la pregunta que ningún inventario
// contesta y que en soporte se hace todo el tiempo — *¿qué le pasó a este equipo
// mientras nadie lo miraba?*
//
// Tres cosas, en este orden:
//
//  1. Sesiones: cada vez que el equipo se encendió, cuánto estuvo prendido y
//     CÓMO terminó (apagado ordenado, reinicio o de golpe). Un apagón brusco no
//     deja rastro en ninguna otra pestaña: el registro simplemente se corta.
//  2. Tareas automáticas: lo que el equipo hace solo (temporizadores, tareas de
//     cron y los servicios que se le añadieron), con la ÚLTIMA vez que corrió
//     cada una y si terminó bien. Sin esto, "el respaldo no se hizo" obliga a
//     abrir una terminal para saber si siquiera se intentó.
//  3. Al iniciar sesión: qué programas se lanzan con la sesión gráfica y si
//     están corriendo AHORA. Un programa de autoarranque que no arrancó (porque
//     nadie inició sesión, o porque el entorno gráfico se cayó) es invisible
//     hasta que se echa de menos lo que hacía.
//
// Contrato: GET /arranques → BootsReport. Espejo en
// pcinfo/lib/models/arranques.dart.

// Cuántas sesiones se devuelven como máximo (de la más reciente hacia atrás).
const maxSesiones = 20

// Cómo terminó una sesión (campo Ended).
const (
	FinNormal   = "normal"   // apagado ordenado
	FinReinicio = "reinicio" // reinicio ordenado
	FinBrusco   = "brusco"   // el registro se corta de golpe
	FinEnCurso  = "encurso"  // la sesión actual, aún no ha terminado
)

// Tipo de tarea automática (campo Kind).
const (
	TareaTemporizador = "temporizador" // systemd .timer / tarea programada
	TareaCron         = "cron"
	TareaServicio     = "servicio" // servicio añadido al equipo
)

// Estado de una tarea (campo State).
const (
	EstadoActivo        = "activo"  // habilitada y sin fallos
	EstadoFallido       = "fallido" // su última ejecución terminó mal
	EstadoDeshabilitado = "deshabilitado"
	EstadoDesconocido   = "desconocido"
)

// BootSession es UNA sesión del equipo: del encendido al apagado.
type BootSession struct {
	Index     int    `json:"index"`     // 0 = la sesión actual; -1 la anterior…
	Start     string `json:"start"`     // "2026-09-06 06:30:12"
	End       string `json:"end"`       // vacío si es la actual
	SecondsUp int64  `json:"secondsUp"` // cuánto estuvo encendido
	Ended     string `json:"ended"`     // ver constantes Fin*
	Kernel    string `json:"kernel"`    // versión del núcleo de esa sesión

	// Última línea registrada antes del corte. Solo se llena cuando el apagado
	// fue brusco: es lo único que queda para saber qué estaba haciendo el equipo
	// en ese momento.
	LastLine string `json:"lastLine"`
	Note     string `json:"note"` // qué significa, ya redactado en español
}

// AutoTask es algo que el equipo ejecuta solo: un temporizador, una tarea de
// cron o un servicio enganchado a un momento del arranque o del apagado.
type AutoTask struct {
	Name        string `json:"name"`
	Kind        string `json:"kind"`        // ver constantes Tarea*
	Description string `json:"description"` // para qué es, si el sistema lo dice
	Trigger     string `json:"trigger"`     // cuándo se dispara, en español llano
	Command     string `json:"command"`     // qué ejecuta
	State       string `json:"state"`       // ver constantes Estado*
	LastRun     string `json:"lastRun"`     // última vez que corrió
	NextRun     string `json:"nextRun"`     // próxima vez prevista (temporizadores)
	Result      string `json:"result"`      // cómo terminó la última vez
	Source      string `json:"source"`      // archivo del que sale
	FromSystem  bool   `json:"fromSystem"`  // vino con el sistema operativo

	// AtShutdown: se ejecuta AL APAGAR el equipo. Cambia cómo hay que leer
	// LastRun: systemd olvida el estado de los servicios en cada arranque, así
	// que uno de apagado siempre se ve "sin ejecutar" desde la sesión siguiente
	// — y eso NO significa que no corriera, significa que no se puede saber
	// desde aquí. Sin esta distinción, la pantalla acusaría todos los días a un
	// respaldo que sí se está haciendo.
	AtShutdown bool `json:"atShutdown"`
}

// StartupItem es un programa que se lanza al iniciar sesión.
type StartupItem struct {
	Name    string `json:"name"`
	Command string `json:"command"`
	Source  string `json:"source"` // ruta del archivo que lo declara
	Scope   string `json:"scope"`  // "todos los usuarios" | "usuario tuxor"
	Enabled bool   `json:"enabled"`
	Running bool   `json:"running"` // ¿está en ejecución AHORA?
	Note    string `json:"note"`
}

// BootsReport es la raíz del JSON de GET /arranques.
type BootsReport struct {
	OS        string `json:"os"`
	Elevated  bool   `json:"elevated"`
	Source    string `json:"source"`
	Available bool   `json:"available"`
	Reason    string `json:"reason"`
	ScanDays  int    `json:"scanDays"`

	// JournalVolatile: el diario del sistema no se guarda en disco y se borra en
	// cada apagado (lo normal en Mint y Ubuntu). La GUI ofrece activarlo, porque
	// sin él no hay forma de saber QUÉ pasó en una sesión anterior.
	JournalVolatile bool `json:"journalVolatile"`

	Sessions []BootSession `json:"sessions"`
	Tasks    []AutoTask    `json:"tasks"`
	Startup  []StartupItem `json:"startup"`

	// Advertencias de lectura: qué parte se quedó corta y por qué. La GUI las
	// muestra tal cual para no dar por bueno un listado incompleto.
	SessionsNote string `json:"sessionsNote"`
	TasksNote    string `json:"tasksNote"`
	StartupNote  string `json:"startupNote"`
}

// ResultadoAccion es lo que devuelve una acción que MODIFICA el equipo. PCInfo
// es una herramienta de lectura: las poquísimas cosas que escribe van por aquí,
// y siempre dicen en español qué pasó y, si falló, qué hacer a mano.
type ResultadoAccion struct {
	Ok      bool   `json:"ok"`
	Message string `json:"message"`
	Detail  string `json:"detail"`
}

// ActivaDiarioPersistente hace que el diario del sistema se guarde en disco.
// Necesita permisos de administrador: los pide con el diálogo del sistema.
func ActivaDiarioPersistente() ResultadoAccion {
	return safe("diario", activaDiarioPersistente)
}

// CollectBoots arma el reporte de encendidos y apagados. Igual que el resto de
// colectores va envuelto en safe(): si algo entra en pánico devuelve un reporte
// vacío en vez de tumbar el endpoint.
func CollectBoots() BootsReport {
	rep := safe("arranques", collectBoots)
	if rep.OS == "" {
		rep.OS = runtime.GOOS
	}
	if rep.ScanDays == 0 {
		rep.ScanDays = diasAnalisis
	}
	if rep.Sessions == nil {
		rep.Sessions = []BootSession{}
	}
	if rep.Tasks == nil {
		rep.Tasks = []AutoTask{}
	}
	if rep.Startup == nil {
		rep.Startup = []StartupItem{}
	}
	if len(rep.Sessions) > maxSesiones {
		rep.Sessions = rep.Sessions[:maxSesiones]
	}
	return rep
}

// duracionLlana convierte segundos encendido en "2 h 15 min", que es como se
// lee de un vistazo. Se calcula aquí (no en la GUI) para que el reporte en
// Markdown y la pantalla digan exactamente lo mismo.
func duracionLlana(seg int64) string {
	if seg <= 0 {
		return ""
	}
	d := seg / 86400
	h := (seg % 86400) / 3600
	m := (seg % 3600) / 60
	partes := []string{}
	if d > 0 {
		partes = append(partes, strconv.FormatInt(d, 10)+" d")
	}
	if h > 0 {
		partes = append(partes, strconv.FormatInt(h, 10)+" h")
	}
	if m > 0 && d == 0 {
		partes = append(partes, strconv.FormatInt(m, 10)+" min")
	}
	if len(partes) == 0 {
		return "menos de 1 min"
	}
	return strings.Join(partes, " ")
}
