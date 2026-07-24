// Backend de PCInfo: servidor HTTP local que expone el inventario de hardware
// en JSON para la GUI Flutter. Endpoint principal: GET /hardware.
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"pcinfo-backend/collector"
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
	mux.HandleFunc("/hardware", handleHardware)
	mux.HandleFunc("/errores", handleErrores)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok"))
	})

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

func handleHardware(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/hardware", collector.Collect())
}

// handleErrores sirve el "Historial de Errores": pantallazos azules y registro de
// eventos en Windows, journald/kernel en Linux, ya interpretados. Va aparte de
// /hardware porque es más lento y la GUI solo lo pide al abrir esa pestaña.
func handleErrores(w http.ResponseWriter, _ *http.Request) {
	responde(w, "/errores", collector.CollectErrors())
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
