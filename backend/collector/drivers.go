package collector

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// Módulo "Controladores": respaldar y restaurar los controladores de terceros y
// los perfiles de redes WiFi del equipo.
//
// Contrato:
//
//	GET  /controladores            → DriversReport (qué hay y si se puede operar)
//	POST /controladores/respaldar  → {carpeta, drivers, wifi} → arranca la tarea
//	POST /controladores/restaurar  → {carpeta, drivers, wifi} → arranca la tarea
//	GET  /controladores/tarea      → TareaInfo (avance en vivo)
//
// Espejo en pcinfo/lib/models/controladores.dart.
//
// SOLO WINDOWS (decisión de producto, 2026-08-19): en Linux los controladores
// vienen en el kernel y la distribución los reinstala sola, así que respaldarlos
// no tiene sentido. En Linux el módulo responde Supported=false con el motivo.
//
// Es el PRIMER módulo de PCInfo que ESCRIBE en el sistema. Por eso:
//   - Restaurar y respaldar corren como TAREA en segundo plano con avance en
//     vivo: Export-WindowsDriver tarda minutos y sin avance la app parecería
//     colgada.
//   - Solo puede haber UNA tarea a la vez (restaurar controladores dos veces en
//     paralelo dejaría el equipo en un estado imposible de razonar).
//   - Todo requiere permisos de administrador; si el backend no está elevado se
//     dice antes de empezar, no a mitad de la operación.

// Acciones de tarea (campo Kind de TareaInfo).
const (
	TareaRespaldar = "respaldar"
	TareaRestaurar = "restaurar"
)

// Nivel de cada paso del registro de la tarea.
const (
	PasoInfo  = "info"
	PasoOK    = "ok"
	PasoAviso = "aviso"
	PasoError = "error"
)

// Subcarpetas del respaldo. Se fijan aquí para que restaurar encuentre lo que
// respaldó, aunque el usuario elija la carpeta padre.
const (
	CarpetaDrivers = "Controladores"
	CarpetaWifi    = "RedesWiFi"
)

// DriverItem es un controlador de terceros instalado (los de la propia imagen de
// Windows no se listan: no se respaldan ni se restauran).
type DriverItem struct {
	Name     string `json:"name"`     // oem12.inf — como lo conoce Windows
	Original string `json:"original"` // nombre original del .inf del fabricante
	Class    string `json:"class"`    // Sistema, Impresoras, Red…
	Provider string `json:"provider"` // fabricante que lo firma
	Version  string `json:"version"`
	Date     string `json:"date"` // "2026-07-23"
}

// WifiProfile es una red WiFi guardada en el equipo.
type WifiProfile struct {
	Name     string `json:"name"`     // SSID como se ve en la lista de redes
	Auth     string `json:"auth"`     // WPA2PSK, WPA3SAE, open…
	Password string `json:"password"` // vacío si no se pudo leer (hace falta admin)
}

// DriversReport es la respuesta de GET /controladores.
type DriversReport struct {
	OS        string        `json:"os"`
	Supported bool          `json:"supported"` // ¿el módulo existe en este sistema?
	Elevated  bool          `json:"elevated"`  // ¿el backend corre como administrador?
	Available bool          `json:"available"` // ¿se pudo leer el inventario?
	Reason    string        `json:"reason"`    // aviso o motivo del fallo
	Drivers   []DriverItem  `json:"drivers"`
	Wifi      []WifiProfile `json:"wifi"`
}

// PasoTarea es una línea del registro de avance de una tarea.
type PasoTarea struct {
	When  string `json:"when"`  // hora local "14:02:11"
	Text  string `json:"text"`  // qué pasó
	Level string `json:"level"` // info | ok | aviso | error
}

// TareaInfo es el estado de la tarea en curso (o de la última que terminó).
type TareaInfo struct {
	ID       string      `json:"id"`
	Kind     string      `json:"kind"`     // respaldar | restaurar
	Drivers  bool        `json:"drivers"`  // ¿incluye controladores?
	Wifi     bool        `json:"wifi"`     // ¿incluye redes WiFi?
	Folder   string      `json:"folder"`   // carpeta elegida por el usuario
	Running  bool        `json:"running"`  // ¿sigue trabajando?
	Done     bool        `json:"done"`     // ¿terminó (bien o mal)?
	OK       bool        `json:"ok"`       // terminó sin errores
	Started  string      `json:"started"`  // "2026-08-19 14:02:11"
	Finished string      `json:"finished"` // idem, vacío mientras corre
	Error    string      `json:"error"`    // motivo si terminó mal
	Summary  string      `json:"summary"`  // resumen en una línea para la GUI
	Omitted  int         `json:"omitted"`  // líneas del registro descartadas por el tope
	Steps    []PasoTarea `json:"steps"`
}

// PeticionTarea es el cuerpo de POST /controladores/{respaldar,restaurar}.
type PeticionTarea struct {
	Carpeta string `json:"carpeta"`
	Drivers bool   `json:"drivers"`
	Wifi    bool   `json:"wifi"`
}

// tarea guarda el estado de la única tarea que puede correr a la vez.
var tarea = struct {
	sync.Mutex
	info   TareaInfo
	cancel context.CancelFunc
}{}

// CollectDrivers arma el inventario de controladores y redes WiFi.
func CollectDrivers() DriversReport {
	rep := safe("controladores", estadoControladores)
	if rep.Drivers == nil {
		rep.Drivers = []DriverItem{}
	}
	if rep.Wifi == nil {
		rep.Wifi = []WifiProfile{}
	}
	if rep.OS == "" {
		rep.OS = runtime.GOOS
	}
	return rep
}

// EstadoTarea devuelve una copia del estado actual (o el de la última tarea).
func EstadoTarea() TareaInfo {
	tarea.Lock()
	defer tarea.Unlock()
	info := tarea.info
	info.Steps = append([]PasoTarea{}, tarea.info.Steps...)
	return info
}

// IniciaTarea arranca un respaldo o una restauración en segundo plano. Devuelve
// el estado inicial; si no se puede empezar, el error explica por qué.
func IniciaTarea(kind string, p PeticionTarea) (TareaInfo, error) {
	if !p.Drivers && !p.Wifi {
		return TareaInfo{}, fmt.Errorf("no se eligió qué %s: marca controladores, redes WiFi o ambos", kind)
	}
	if strings.TrimSpace(p.Carpeta) == "" {
		return TareaInfo{}, fmt.Errorf("falta la carpeta de destino")
	}
	rep := CollectDrivers()
	if !rep.Supported {
		return TareaInfo{}, fmt.Errorf("%s", rep.Reason)
	}
	if !rep.Elevated {
		return TareaInfo{}, fmt.Errorf(
			"hace falta ejecutar PCInfo como administrador para %s controladores y redes WiFi", kind)
	}

	tarea.Lock()
	if tarea.info.Running {
		en := tarea.info.Kind
		tarea.Unlock()
		return TareaInfo{}, fmt.Errorf("ya hay una tarea en curso (%s); espera a que termine", en)
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeoutTarea)
	tarea.cancel = cancel
	tarea.info = TareaInfo{
		ID:      fmt.Sprintf("%s-%d", kind, time.Now().UnixNano()),
		Kind:    kind,
		Drivers: p.Drivers,
		Wifi:    p.Wifi,
		Folder:  p.Carpeta,
		Running: true,
		Started: time.Now().Format("2006-01-02 15:04:05"),
		Steps:   []PasoTarea{},
	}
	info := tarea.info
	tarea.Unlock()

	go corretarea(ctx, cancel, kind, p)
	return info, nil
}

// CancelaTarea aborta la tarea en curso, si la hay.
func CancelaTarea() bool {
	tarea.Lock()
	defer tarea.Unlock()
	if !tarea.info.Running || tarea.cancel == nil {
		return false
	}
	tarea.cancel()
	return true
}

// Tiempo máximo de una tarea completa. Exportar los controladores de un equipo
// con muchos dispositivos puede acercarse a la media hora.
const timeoutTarea = 45 * time.Minute

func corretarea(ctx context.Context, cancel context.CancelFunc, kind string, p PeticionTarea) {
	defer cancel()
	var err error
	switch kind {
	case TareaRespaldar:
		err = respalda(ctx, p)
	case TareaRestaurar:
		err = restaura(ctx, p)
	default:
		err = fmt.Errorf("acción desconocida: %s", kind)
	}
	cierraTarea(err)
}

// respalda ejecuta las partes elegidas del respaldo, sin abortar el conjunto si
// una falla: si los controladores se exportan pero las redes no, el usuario se
// queda igualmente con los controladores.
func respalda(ctx context.Context, p PeticionTarea) error {
	var fallos []string
	if p.Drivers {
		paso(PasoInfo, "Exportando los controladores instalados…")
		if err := respaldaControladores(ctx, rutaDe(p.Carpeta, CarpetaDrivers)); err != nil {
			paso(PasoError, "Controladores: "+err.Error())
			fallos = append(fallos, "controladores")
		} else {
			paso(PasoOK, "Controladores respaldados.")
		}
	}
	if p.Wifi {
		paso(PasoInfo, "Exportando las redes WiFi guardadas…")
		if err := respaldaWifi(ctx, rutaDe(p.Carpeta, CarpetaWifi)); err != nil {
			paso(PasoError, "Redes WiFi: "+err.Error())
			fallos = append(fallos, "redes WiFi")
		} else {
			paso(PasoOK, "Redes WiFi respaldadas. OJO: los archivos .xml contienen las contraseñas en texto legible.")
		}
	}
	if len(fallos) > 0 {
		return fmt.Errorf("no se pudo respaldar: %s", strings.Join(fallos, " y "))
	}
	return nil
}

func restaura(ctx context.Context, p PeticionTarea) error {
	var fallos []string
	if p.Drivers {
		paso(PasoInfo, "Instalando los controladores del respaldo…")
		if err := restauraControladores(ctx, rutaDe(p.Carpeta, CarpetaDrivers)); err != nil {
			paso(PasoError, "Controladores: "+err.Error())
			fallos = append(fallos, "controladores")
		} else {
			paso(PasoOK, "Controladores restaurados. Reinicia el equipo para que Windows los use.")
		}
	}
	if p.Wifi {
		paso(PasoInfo, "Añadiendo las redes WiFi del respaldo…")
		if err := restauraWifi(ctx, rutaDe(p.Carpeta, CarpetaWifi)); err != nil {
			paso(PasoError, "Redes WiFi: "+err.Error())
			fallos = append(fallos, "redes WiFi")
		} else {
			paso(PasoOK, "Redes WiFi restauradas.")
		}
	}
	if len(fallos) > 0 {
		return fmt.Errorf("no se pudo restaurar: %s", strings.Join(fallos, " y "))
	}
	return nil
}

// paso añade una línea al registro de avance de la tarea en curso.
func paso(nivel, texto string) {
	texto = strings.TrimSpace(texto)
	if texto == "" {
		return
	}
	tarea.Lock()
	defer tarea.Unlock()
	if !tarea.info.Running {
		return
	}
	// Tope de líneas: pnputil puede escupir miles y la respuesta JSON se haría
	// enorme. Se conservan las PRIMERAS (dicen qué se empezó a hacer) y las
	// ÚLTIMAS (dicen cómo acabó): lo que se descarta es el medio, sustituido por
	// una línea que dice cuántas se omitieron.
	if len(tarea.info.Steps) >= maxPasos {
		mitad := maxPasos / 2
		tarea.info.Omitted++
		tarea.info.Steps[mitad] = PasoTarea{
			Text:  fmt.Sprintf("… (%d líneas intermedias omitidas)", tarea.info.Omitted),
			Level: PasoInfo,
		}
		tarea.info.Steps = append(tarea.info.Steps[:mitad+1], tarea.info.Steps[mitad+2:]...)
	}
	tarea.info.Steps = append(tarea.info.Steps, PasoTarea{
		When:  time.Now().Format("15:04:05"),
		Text:  recorta(texto, 400),
		Level: nivel,
	})
}

const maxPasos = 400

func cierraTarea(err error) {
	tarea.Lock()
	defer tarea.Unlock()
	tarea.info.Running = false
	tarea.info.Done = true
	tarea.info.Finished = time.Now().Format("2006-01-02 15:04:05")
	tarea.info.OK = err == nil
	if err != nil {
		tarea.info.Error = err.Error()
		tarea.info.Summary = "La operación terminó con errores."
		return
	}
	que := []string{}
	if tarea.info.Drivers {
		que = append(que, "controladores")
	}
	if tarea.info.Wifi {
		que = append(que, "redes WiFi")
	}
	verbo := "Respaldo"
	if tarea.info.Kind == TareaRestaurar {
		verbo = "Restauración"
	}
	tarea.info.Summary = fmt.Sprintf("%s de %s completado en %s.",
		verbo, strings.Join(que, " y "), tarea.info.Folder)
}

// correLineas ejecuta un comando informando de CADA línea que imprime, en vivo.
// Sin esto una tarea de varios minutos no tendría nada que mostrar hasta acabar.
func correLineas(ctx context.Context, cmd *exec.Cmd, linea func(string)) error {
	salida, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return err
	}
	lee(salida, linea)
	err = cmd.Wait()
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("la operación tardó demasiado y se canceló")
	}
	if ctx.Err() == context.Canceled {
		return fmt.Errorf("la operación se canceló")
	}
	return err
}

// rutaDe compone la subcarpeta del respaldo dentro de la carpeta elegida.
func rutaDe(carpeta, sub string) string {
	return filepath.Join(carpeta, sub)
}

func lee(r io.Reader, linea func(string)) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if t := strings.TrimSpace(sc.Text()); t != "" {
			linea(t)
		}
	}
}
