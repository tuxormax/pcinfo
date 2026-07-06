//go:build !windows

package main

// runService (no Windows): no hay servicio; levanta el servidor directamente.
func runService(addr string) { runServer(addr) }

// handleServiceControl (no Windows): no hay subcomandos de servicio.
func handleServiceControl(cmd, addr string) bool { return false }
