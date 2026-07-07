//go:build !windows

package main

// watchParent es un no-op fuera de Windows: en Linux el backend corre como
// servicio systemd (root) y no lo lanza la GUI, así que no vigila a nadie.
func watchParent(pid int) {}
