//go:build darwin

package main

import (
	"os"
	"syscall"
	"time"
)

// watchParent bloquea hasta que el proceso pid (la GUI) termina y entonces
// cierra el backend. Necesario en macOS por la misma razón que en Windows: aquí
// el backend NO es un servicio, es un proceso hijo que la GUI lanza `detached`
// (dentro del .app, Contents/MacOS/pcinfo-backend). Al salir la app, Flutter no
// garantiza que corra ningún cierre ordenado en Dart, así que sin este vigilante
// el backend se queda vivo ocupando el puerto 51247 — comprobado el 12-sep-2026
// en la Mac mini: la app cerrada y el backend en pie.
//
// Se sondea en vez de esperar un handle porque en macOS no hay equivalente a
// WaitForSingleObject sobre un proceso ajeno: `kill(pid, 0)` es la forma
// portable de preguntar "¿sigue existiendo?". EPERM cuenta como vivo (existe,
// pero es de otro usuario); solo ESRCH significa que ya no está.
func watchParent(pid int) {
	for {
		time.Sleep(2 * time.Second)
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
			os.Exit(0)
		}
	}
}
