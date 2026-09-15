package collector

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"
)

// Módulo "Tienda Windows": instala apps de la Microsoft Store SIN abrir la
// Store (catálogo curado, buscador de la Store o un enlace/ProductId a mano),
// descargando los paquetes de Microsoft vía store.rg-adguard.net e
// instalándolos con Add-AppxPackage/DISM.
//
// Portado de la herramienta suelta de tuxor `windows/mitiendawindows`
// (probada en campo): se reutiliza tal cual su "Núcleo" de trabajo
// (tienda_windows.ps1), cambiando la GUI WinForms por esta pestaña.
//
// Contrato:
//
//	GET  /tienda                → TiendaInfo (catálogo + si se puede operar)
//	GET  /tienda/buscar?q=...   → []AppTienda
//	POST /tienda/instalar       → {apps, arch, ring, todos} → arranca la tarea
//	GET  /tienda/tarea          → TareaTiendaInfo (avance en vivo)
//	POST /tienda/cancelar       → aborta la tarea en curso
//
// Espejo en pcinfo/lib/models/tienda.dart.
//
// SOLO WINDOWS. Es el SEGUNDO módulo de PCInfo que ESCRIBE en el sistema
// (el primero es Controladores) y comparte su mismo diseño: tarea en 2º
// plano con avance línea a línea, una sola tarea a la vez, y depende de
// administrador (DISM y, en la práctica, la propia herramienta original así
// lo exige).
//
// ⚠️ A diferencia del resto de PCInfo, este módulo depende de DOS servicios
// de TERCEROS fuera de nuestro control: store.rg-adguard.net (resuelve los
// enlaces de descarga; detrás de Cloudflare) y la API de búsqueda no oficial
// de la Store. Si Cloudflare bloquea la petición, el script lo explica en el
// propio mensaje de error — no es un fallo de PCInfo.

// AppTienda es una app identificada por su ProductId de la Microsoft Store.
type AppTienda struct {
	Nombre    string `json:"nombre"`
	ProductID string `json:"productId"`
}

// CatalogoTienda son las apps más pedidas al formatear un equipo. ProductId
// verificados en sep-2026 (misma lista que la herramienta original) —
// Microsoft puede retirarlos o cambiarlos sin aviso.
var CatalogoTienda = []AppTienda{
	{Nombre: "Fotos", ProductID: "9WZDNCRFJBH4"},
	{Nombre: "Calculadora", ProductID: "9WZDNCRFHVN5"},
	{Nombre: "Cámara", ProductID: "9WZDNCRFJBBG"},
	{Nombre: "Grabadora de voz", ProductID: "9WZDNCRFHWKN"},
	{Nombre: "Recortes (Snipping Tool)", ProductID: "9MZ95KL8MR0L"},
	{Nombre: "Notas rápidas", ProductID: "9NBLGGH4QGHW"},
	{Nombre: "Reloj y alarmas", ProductID: "9WZDNCRFJ3PR"},
	{Nombre: "Microsoft Store", ProductID: "9WZDNCRFJBMP"},
	{Nombre: "Paint", ProductID: "9PCFS5B6T72H"},
	{Nombre: "Bloc de notas", ProductID: "9MSMLRH6LZF3"},
	{Nombre: "Correo y Calendario", ProductID: "9WZDNCRFHVQM"},
	{Nombre: "WhatsApp", ProductID: "9NKSQGP7F2NH"},
	{Nombre: "Spotify", ProductID: "9NCBCSZSJRSB"},
	{Nombre: "Netflix", ProductID: "9WZDNCRFJ3TJ"},
	{Nombre: "Prime Video", ProductID: "9P6RC76MSMMJ"},
	{Nombre: "Disney+", ProductID: "9NXQXXLFST89"},
}

// TiendaInfo es la respuesta de GET /tienda.
type TiendaInfo struct {
	OS        string      `json:"os"`
	Supported bool        `json:"supported"`
	Elevated  bool        `json:"elevated"`
	Reason    string      `json:"reason"`
	Catalogo  []AppTienda `json:"catalogo"`
}

// PasoTiendaTarea es una línea del registro de avance de una instalación.
type PasoTiendaTarea struct {
	When  string `json:"when"`
	Text  string `json:"text"`
	Level string `json:"level"` // info | ok | aviso | error
}

// TareaTiendaInfo es el estado de la instalación en curso (o de la última).
type TareaTiendaInfo struct {
	ID       string            `json:"id"`
	Apps     []AppTienda       `json:"apps"`
	Running  bool              `json:"running"`
	Done     bool              `json:"done"`
	OK       bool              `json:"ok"`
	Started  string            `json:"started"`
	Finished string            `json:"finished"`
	Error    string            `json:"error"`
	Summary  string            `json:"summary"`
	Omitted  int               `json:"omitted"`
	Steps    []PasoTiendaTarea `json:"steps"`
}

// PeticionInstalar es el cuerpo de POST /tienda/instalar.
type PeticionInstalar struct {
	Apps  []AppTienda `json:"apps"`
	// Carpeta, si viene, instala los paquetes YA DESCARGADOS de esa carpeta
	// (respaldo cuando Cloudflare bloquea rg-adguard) y Apps se ignora.
	Carpeta string `json:"carpeta"`
	Arch    string `json:"arch"`  // Auto | x64 | x86 | arm64
	Ring    string `json:"ring"`  // Retail | RP | WIS | WIF
	Todos   bool   `json:"todos"` // instalar para todos los usuarios (DISM)
}

// CollectTienda arma el estado del módulo (catálogo + si se puede operar).
func CollectTienda() TiendaInfo {
	rep := safe("tienda", estadoTienda)
	if rep.Catalogo == nil {
		rep.Catalogo = []AppTienda{}
	}
	if rep.OS == "" {
		rep.OS = runtime.GOOS
	}
	return rep
}

// BuscarTienda consulta el buscador de la Store por nombre.
func BuscarTienda(consulta string) ([]AppTienda, error) {
	if strings.TrimSpace(consulta) == "" {
		return nil, fmt.Errorf("escribe algo para buscar")
	}
	return buscaTienda(consulta)
}

// tareaTienda guarda el estado de la única instalación que puede correr a la
// vez (mutex propio: independiente del de Controladores, un técnico podría
// querer respaldar controladores mientras instala apps).
var tareaTienda = struct {
	sync.Mutex
	info   TareaTiendaInfo
	cancel context.CancelFunc
}{}

// IniciaInstalacion arranca la instalación en segundo plano.
func IniciaInstalacion(p PeticionInstalar) (TareaTiendaInfo, error) {
	if p.Carpeta == "" && len(p.Apps) == 0 {
		return TareaTiendaInfo{}, fmt.Errorf("no hay ninguna app en la lista para instalar")
	}
	rep := CollectTienda()
	if !rep.Supported {
		return TareaTiendaInfo{}, fmt.Errorf("%s", rep.Reason)
	}
	if !rep.Elevated {
		return TareaTiendaInfo{}, fmt.Errorf(
			"hace falta ejecutar PCInfo como administrador para instalar apps de la Tienda")
	}

	tareaTienda.Lock()
	if tareaTienda.info.Running {
		tareaTienda.Unlock()
		return TareaTiendaInfo{}, fmt.Errorf("ya hay una instalación en curso; espera a que termine")
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeoutTareaTienda)
	tareaTienda.cancel = cancel
	tareaTienda.info = TareaTiendaInfo{
		ID:      fmt.Sprintf("instalar-%d", time.Now().UnixNano()),
		Apps:    p.Apps,
		Running: true,
		Started: time.Now().Format("2006-01-02 15:04:05"),
		Steps:   []PasoTiendaTarea{},
	}
	info := tareaTienda.info
	tareaTienda.Unlock()

	go corretareaTienda(ctx, cancel, p)
	return info, nil
}

// EstadoTareaTienda devuelve una copia del estado actual (o el de la última).
func EstadoTareaTienda() TareaTiendaInfo {
	tareaTienda.Lock()
	defer tareaTienda.Unlock()
	info := tareaTienda.info
	info.Steps = append([]PasoTiendaTarea{}, tareaTienda.info.Steps...)
	return info
}

// CancelaTareaTienda aborta la instalación en curso, si la hay.
func CancelaTareaTienda() bool {
	tareaTienda.Lock()
	defer tareaTienda.Unlock()
	if !tareaTienda.info.Running || tareaTienda.cancel == nil {
		return false
	}
	tareaTienda.cancel()
	return true
}

// Cada app puede tardar minutos (descarga + instalación + DISM); una lista
// larga del catálogo podría acercarse a la media hora.
const timeoutTareaTienda = 45 * time.Minute

func corretareaTienda(ctx context.Context, cancel context.CancelFunc, p PeticionInstalar) {
	defer cancel()
	var err error
	if p.Carpeta != "" {
		err = instalaCarpeta(ctx, p.Carpeta, p.Arch, p.Todos)
	} else {
		err = instalaApps(ctx, p.Apps, p.Arch, p.Ring, p.Todos)
	}
	cierraTareaTienda(err)
}

func pasoTienda(nivel, texto string) {
	texto = strings.TrimSpace(texto)
	if texto == "" {
		return
	}
	tareaTienda.Lock()
	defer tareaTienda.Unlock()
	if !tareaTienda.info.Running {
		return
	}
	// Mismo tope y mismo criterio que Controladores: se conservan las
	// primeras líneas (qué se empezó a hacer) y las últimas (cómo acabó).
	if len(tareaTienda.info.Steps) >= maxPasosTienda {
		mitad := maxPasosTienda / 2
		tareaTienda.info.Omitted++
		tareaTienda.info.Steps[mitad] = PasoTiendaTarea{
			Text:  fmt.Sprintf("… (%d líneas intermedias omitidas)", tareaTienda.info.Omitted),
			Level: PasoInfo,
		}
		tareaTienda.info.Steps = append(tareaTienda.info.Steps[:mitad+1], tareaTienda.info.Steps[mitad+2:]...)
	}
	tareaTienda.info.Steps = append(tareaTienda.info.Steps, PasoTiendaTarea{
		When:  time.Now().Format("15:04:05"),
		Text:  recorta(texto, 400),
		Level: nivel,
	})
}

const maxPasosTienda = 400

func cierraTareaTienda(err error) {
	tareaTienda.Lock()
	defer tareaTienda.Unlock()
	tareaTienda.info.Running = false
	tareaTienda.info.Done = true
	tareaTienda.info.Finished = time.Now().Format("2006-01-02 15:04:05")
	tareaTienda.info.OK = err == nil
	if err != nil {
		tareaTienda.info.Error = err.Error()
		tareaTienda.info.Summary = "La instalación terminó con errores."
		return
	}
	tareaTienda.info.Summary = fmt.Sprintf("%d app(s) procesadas.", len(tareaTienda.info.Apps))
}

// correLineasTienda ejecuta un comando informando de CADA línea que imprime,
// en vivo (mismo helper que Controladores, con su propio nombre para no
// mezclar los dos módulos por accidente).
func correLineasTienda(ctx context.Context, cmd *exec.Cmd, linea func(string)) error {
	salida, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return err
	}
	leeTienda(salida, linea)
	err = cmd.Wait()
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("la instalación tardó demasiado y se canceló")
	}
	if ctx.Err() == context.Canceled {
		return fmt.Errorf("la instalación se canceló")
	}
	return err
}

func leeTienda(r io.Reader, linea func(string)) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if t := strings.TrimSpace(sc.Text()); t != "" {
			linea(t)
		}
	}
}
