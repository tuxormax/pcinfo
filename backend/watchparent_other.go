//go:build !windows && !darwin

package main

// watchParent es un no-op en Linux y en el resto: ahí el backend corre como
// servicio systemd (root) y no lo lanza la GUI, así que no vigila a nadie.
// Windows y macOS SÍ vigilan (el backend es hijo de la GUI) y tienen su propio
// archivo: watchparent_windows.go y watchparent_darwin.go.
func watchParent(pid int) {}
