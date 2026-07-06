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
	flag.Parse()
	// La GUI lo lanza como proceso hijo mientras la app está abierta y lo mata al
	// cerrar (estilo HWiNFO: sin servicio en 2º plano). En Windows se compila con
	// -H windowsgui, así que no abre ventana de consola.
	runServer(*addr)
}

// runServer levanta el servidor HTTP y bloquea.
func runServer(addr string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/hardware", handleHardware)
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
	hw := collector.Collect()

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(hw); err != nil {
		log.Printf("error serializando /hardware: %v", err)
		http.Error(w, "error interno", http.StatusInternalServerError)
	}
}
