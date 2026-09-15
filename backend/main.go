// Backend de PCInfo: servidor HTTP local que expone el inventario de hardware
// en JSON para la GUI Flutter. Endpoint principal: GET /hardware.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"runtime/debug"
	"strconv"
	"time"

	"pcinfo-backend/collector"
)

// Versión con la que se compiló el backend. La inyectan los scripts de
// construcción desde pcinfo/lib/version.dart (única fuente de verdad):
//
//	go build -ldflags "-X main.buildVersion=1.2 -X main.buildRevision=31"
//
// En una compilación suelta (desarrollo) queda "dev", y la GUI lo respeta tal
// cual en vez de intentar reemplazar el backend.
var (
	buildVersion  = "dev"
	buildRevision = "0"
)

func main() {
	addr := flag.String("addr", defaultAddr(), "dirección de escucha (host:puerto)")
	parentPID := flag.Int("parent-pid", 0, "PID de la GUI; al morir ésta, el backend se cierra")
	flag.Parse()
	// La GUI lo lanza como proceso hijo mientras la app está abierta. En Windows
	// el backend puede correr ELEVADO (Start-Process -Verb RunAs para leer SMART)
	// mientras la GUI es asInvoker: entonces la GUI no puede matarlo (elevación
	// distinta), así que el backend vigila el PID de la GUI y se cierra solo
	// cuando ésta desaparece. Estilo HWiNFO: sin servicio en 2º plano. En Windows
	// se compila con -H windowsgui, así que no abre ventana de consola.
	if *parentPID > 0 {
		go watchParent(*parentPID)
	}
	runServer(*addr)
}

// runServer levanta el servidor HTTP y bloquea.
func runServer(addr string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/hardware", protege("/hardware", handleHardware))
	mux.HandleFunc("/discos", protege("/discos", handleDiscos))
	mux.HandleFunc("/discos/incidencias", protege("/discos/incidencias", handleIncidencias))
	mux.HandleFunc("/errores", protege("/errores", handleErrores))
	mux.HandleFunc("/arranques", protege("/arranques", handleArranques))
	mux.HandleFunc("/arranques/diario", protege("/arranques/diario", handleDiarioPersistente))
	mux.HandleFunc("/software", protege("/software", handleSoftware))
	mux.HandleFunc("/bateria", protege("/bateria", handleBateria))
	mux.HandleFunc("/red", protege("/red", handleRed))
	mux.HandleFunc("/controladores", protege("/controladores", handleControladores))
	mux.HandleFunc("/controladores/tarea", protege("/controladores/tarea", handleTarea))
	mux.HandleFunc("/controladores/respaldar", protege("/controladores/respaldar", handleRespaldar))
	mux.HandleFunc("/controladores/restaurar", protege("/controladores/restaurar", handleRestaurar))
	mux.HandleFunc("/controladores/cancelar", protege("/controladores/cancelar", handleCancelar))
	mux.HandleFunc("/tienda", protege("/tienda", handleTienda))
	mux.HandleFunc("/tienda/buscar", protege("/tienda/buscar", handleTiendaBuscar))
	mux.HandleFunc("/tienda/instalar", protege("/tienda/instalar", handleTiendaInstalar))
	mux.HandleFunc("/tienda/tarea", protege("/tienda/tarea", handleTiendaTarea))
	mux.HandleFunc("/tienda/cancelar", protege("/tienda/cancelar", handleTiendaCancelar))
	mux.HandleFunc("/healthz", handleHealth)

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("PCInfo backend escuchando en http://%s/hardware", addr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("no se pudo iniciar el servidor: %v", err)
	}
}

// defaultAddr permite sobreescribir el puerto con PCINFO_ADDR; por defecto solo
// escucha en loopback (la GUI corre en la misma máquina).
func defaultAddr() string {
	if v := os.Getenv("PCINFO_ADDR"); v != "" {
		return v
	}
	return "127.0.0.1:51247"
}

// handleHealth identifica al backend que está contestando: con qué versión se
// compiló, desde qué ejecutable corre y con qué PID. La GUI lo compara con SU
// propia versión: si el puerto lo ocupa un backend VIEJO que quedó vivo (pasa al
// instalar una versión nueva encima sin cerrar la anterior), la app lo sustituye
// en vez de hablar con él — si no, la versión nueva seguiría mostrando fallos ya
// corregidos, porque quien responde es el binario anterior.
func handleHealth(w http.ResponseWriter, _ *http.Request) {
	exe, _ := os.Executable()
	responde(w, "/healthz", map[string]any{
		"ok":       true,
		"version":  buildVersion,
		"revision": buildRevision,
		"exe":      exe,
		"pid":      os.Getpid(),
	})
}

// protege devuelve el error EN LA RESPUESTA si el colector se rompe. Sin esto un
// panic corta la conexión y la GUI solo puede decir "el servicio no responde",
// que es indistinguible de un backend caído y no deja diagnosticar nada en un
// equipo ajeno. Ahora la app recibe el mensaje y la traza, y puede mostrarlos
// para copiarlos.
func protege(ruta string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			p := recover()
			if p == nil {
				return
			}
			traza := string(debug.Stack())
			log.Printf("fallo interno en %s: %v\n%s", ruta, p, traza)
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok":    false,
				"ruta":  ruta,
				"error": fmt.Sprintf("%v", p),
				"stack": traza,
			})
		}()
		h(w, r)
	}
}

// handleHardware sirve el inventario. Con ?smart=0 se OMITE la salud de los
// discos (S.M.A.R.T.), que es lo único lento del recorrido: un disco que no
// contesta —lector de tarjetas, gabinete USB— se lleva segundos por cada tipo de
// conexión que smartctl prueba, y la GUI corta la espera a los 30 s. Así la app
// abre de inmediato y pide la salud aparte con /discos. Sin el parámetro se
// responde completo, como siempre (una GUI anterior sigue funcionando igual).
func handleHardware(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("smart") == "0" {
		responde(w, "/hardware", collector.CollectSinSmart())
		return
	}
	responde(w, "/hardware", collector.Collect())
}

// handleDiscos sirve SOLO los discos, ya con S.M.A.R.T. Es la segunda parte del
// arranque en dos tiempos: la GUI lo pide en segundo plano y actualiza la ficha
// de Almacenamiento cuando llega.
//
// Parámetro opcional ?forzar=\\.\PHYSICALDRIVE2: sondea ESE disco por puente USB
// aunque se haya clasificado como memoria extraíble. Lo usa el botón "Leer salud
// igual" para el gabinete externo que se declara removible.
func handleDiscos(w http.ResponseWriter, r *http.Request) {
	// Se envuelve en un objeto (no un arreglo suelto) porque la GUI decodifica
	// todas las respuestas como JSON de objeto.
	responde(w, "/discos", map[string]any{
		"discos": collector.CollectDiscos(r.URL.Query().Get("forzar")),
	})
}

// handleIncidencias sirve lo que le ha PASADO a cada disco según el registro del
// sistema: errores de lectura/escritura con la posición exacta del disco,
// desconexiones y reparaciones del sistema de archivos. Va aparte de /discos
// porque la consulta al registro es lenta (~6 s por 24 h) y porque contesta otra
// pregunta: el S.M.A.R.T. es lo que el disco opina de sí mismo; esto es lo que el
// sistema vio fallar. En un disco USB de macOS, además, es la única fuente.
//
// Parámetro opcional ?horas=N (por omisión 24, máximo 720).
func handleIncidencias(w http.ResponseWriter, r *http.Request) {
	horas, _ := strconv.Atoi(r.URL.Query().Get("horas"))
	responde(w, "/discos/incidencias", collector.CollectIncidencias(horas))
}

// handleErrores sirve el "Historial de Errores": pantallazos azules y registro de
// eventos en Windows, journald/kernel en Linux, ya interpretados. Va aparte de
// /hardware porque es más lento y la GUI solo lo pide al abrir esa pestaña.
//
// Parámetro opcional ?raiz=D:\Windows (Windows): analiza esa instalación en vez
// de la que está corriendo. Es lo que usa el selector de unidad de la GUI para
// leer los errores de un equipo que ya no arranca desde un medio de rescate.
func handleErrores(w http.ResponseWriter, r *http.Request) {
	responde(w, "/errores", collector.CollectErrors(r.URL.Query().Get("raiz")))
}

// handleArranques sirve "Encendidos y apagados": el historial de sesiones del
// equipo (con cuáles terminaron de golpe), las tareas que el equipo ejecuta solo
// y los programas que se lanzan al iniciar sesión. Va aparte de /hardware porque
// recorre el diario del sistema y consulta a systemd unidad por unidad.
func handleArranques(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/arranques", collector.CollectBoots())
}

// handleDiarioPersistente activa el diario permanente del sistema. Es de los
// POQUÍSIMOS endpoints que MODIFICAN el equipo, así que —como los de
// controladores— exige POST: un GET puede dispararlo el navegador o un
// precargado, y reiniciar journald no es algo que deba pasar por accidente.
func handleDiarioPersistente(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		fallo(w, http.StatusMethodNotAllowed, "esta operación necesita POST")
		return
	}
	responde(w, "/arranques/diario", collector.ActivaDiarioPersistente())
}

// handleSoftware sirve el "Software instalado". Va aparte de /hardware porque
// recorrer el registro y consultar las apps de la Tienda tarda unos segundos y
// la GUI solo lo pide al abrir esa pestaña.
func handleSoftware(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/software", collector.CollectSoftware())
}

// handleBateria sirve el estado de salud de la batería. Va aparte de /hardware
// porque en Windows hay que pedirle a powercfg que genere su informe, y eso se
// lleva unos segundos: la GUI solo lo pide al abrir esa pestaña.
func handleBateria(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/bateria", collector.CollectBattery())
}

// handleRed sirve lo único que el diagnóstico de red necesita del sistema
// operativo: la IP local y la puerta de enlace. El resto de las pruebas
// (ping, DNS, velocidad, UPnP) las hace la GUI directamente por socket.
func handleRed(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/red", collector.CollectRed())
}

// handleControladores sirve el inventario de controladores de terceros y redes
// WiFi guardadas (pestaña "Controladores"). Solo Windows: en Linux responde con
// Supported=false y el motivo.
func handleControladores(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/controladores", collector.CollectDrivers())
}

// handleTarea informa del avance de la tarea de respaldo/restauración en curso
// (o de la última que terminó). La GUI lo consulta cada segundo mientras corre.
func handleTarea(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/controladores/tarea", collector.EstadoTarea())
}

// handleRespaldar y handleRestaurar arrancan la tarea y devuelven su estado
// inicial. Son los ÚNICOS endpoints de PCInfo que modifican el equipo, así que
// exigen POST: un GET podría dispararse desde el navegador o desde un
// precargado, y restaurar controladores no es algo que deba pasar por accidente.
func handleRespaldar(w http.ResponseWriter, r *http.Request) {
	arrancaTarea(w, r, collector.TareaRespaldar)
}

func handleRestaurar(w http.ResponseWriter, r *http.Request) {
	arrancaTarea(w, r, collector.TareaRestaurar)
}

func arrancaTarea(w http.ResponseWriter, r *http.Request, kind string) {
	if r.Method != http.MethodPost {
		fallo(w, http.StatusMethodNotAllowed, "esta operación necesita POST")
		return
	}
	var p collector.PeticionTarea
	if err := json.NewDecoder(io.LimitReader(r.Body, 64*1024)).Decode(&p); err != nil {
		fallo(w, http.StatusBadRequest, "no se entendió la petición: "+err.Error())
		return
	}
	info, err := collector.IniciaTarea(kind, p)
	if err != nil {
		fallo(w, http.StatusConflict, err.Error())
		return
	}
	responde(w, "/controladores/"+kind, info)
}

// handleCancelar aborta la tarea en curso.
func handleCancelar(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		fallo(w, http.StatusMethodNotAllowed, "esta operación necesita POST")
		return
	}
	responde(w, "/controladores/cancelar", map[string]any{"ok": collector.CancelaTarea()})
}

// handleTienda sirve el catálogo de apps y si se puede instalar (pestaña
// "Tienda Windows"). Solo Windows: en el resto responde Supported=false.
func handleTienda(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/tienda", collector.CollectTienda())
}

// handleTiendaBuscar consulta el buscador de la Store por nombre (?q=...).
func handleTiendaBuscar(w http.ResponseWriter, r *http.Request) {
	apps, err := collector.BuscarTienda(r.URL.Query().Get("q"))
	if err != nil {
		fallo(w, http.StatusBadRequest, err.Error())
		return
	}
	responde(w, "/tienda/buscar", map[string]any{"apps": apps})
}

// handleTiendaTarea informa del avance de la instalación en curso (o de la
// última). La GUI lo consulta cada segundo mientras corre.
func handleTiendaTarea(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/tienda/tarea", collector.EstadoTareaTienda())
}

// handleTiendaInstalar arranca la instalación y devuelve su estado inicial.
// POR POST a propósito, como Controladores: instalar software no es algo que
// deba pasar por accidente con un GET.
func handleTiendaInstalar(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		fallo(w, http.StatusMethodNotAllowed, "esta operación necesita POST")
		return
	}
	var p collector.PeticionInstalar
	if err := json.NewDecoder(io.LimitReader(r.Body, 256*1024)).Decode(&p); err != nil {
		fallo(w, http.StatusBadRequest, "no se entendió la petición: "+err.Error())
		return
	}
	info, err := collector.IniciaInstalacion(p)
	if err != nil {
		fallo(w, http.StatusConflict, err.Error())
		return
	}
	responde(w, "/tienda/instalar", info)
}

// handleTiendaCancelar aborta la instalación en curso.
func handleTiendaCancelar(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		fallo(w, http.StatusMethodNotAllowed, "esta operación necesita POST")
		return
	}
	responde(w, "/tienda/cancelar", map[string]any{"ok": collector.CancelaTareaTienda()})
}

// fallo responde un error de negocio en el MISMO formato que usa protege() para
// los pánicos, para que la GUI lo muestre siempre igual y sea copiable.
func fallo(w http.ResponseWriter, codigo int, mensaje string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(codigo)
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": mensaje})
}

func responde(w http.ResponseWriter, ruta string, dato any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(dato); err != nil {
		log.Printf("error serializando %s: %v", ruta, err)
		http.Error(w, "error interno", http.StatusInternalServerError)
	}
}
