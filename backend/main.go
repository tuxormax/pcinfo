// Backend de PCInfo: servidor HTTP local que expone el inventario de hardware
// en JSON para la GUI Flutter. Endpoint principal: GET /hardware.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime/debug"
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
	mux.HandleFunc("/errores", protege("/errores", handleErrores))
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

func handleHardware(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/hardware", collector.Collect())
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
