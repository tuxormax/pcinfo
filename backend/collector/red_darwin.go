//go:build darwin

package collector

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// defaultGateway parsea "route -n get default": macOS no expone la tabla de
// rutas en un archivo tipo /proc, así que aquí sí hace falta el exec (mismo
// patrón que system_darwin.go con sysctl/system_profiler).
func defaultGateway() (gateway, iface string) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "route", "-n", "get", "default").Output()
	if err != nil {
		return "", ""
	}
	for _, linea := range strings.Split(string(out), "\n") {
		linea = strings.TrimSpace(linea)
		switch {
		case strings.HasPrefix(linea, "gateway:"):
			gateway = strings.TrimSpace(strings.TrimPrefix(linea, "gateway:"))
		case strings.HasPrefix(linea, "interface:"):
			iface = strings.TrimSpace(strings.TrimPrefix(linea, "interface:"))
		}
	}
	return gateway, iface
}
