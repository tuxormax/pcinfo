//go:build darwin

package collector

import (
	"strconv"
	"strings"
)

// sysctlTexto devuelve el valor de una clave de sysctl como texto, o "" si no
// existe. En macOS sysctl es la fuente de casi todo el hardware: no hay DMI.
func sysctlTexto(clave string) string {
	return strings.TrimSpace(cmdOut("sysctl", "-n", clave))
}

// sysctlEntero devuelve el valor de una clave de sysctl como número, o 0.
func sysctlEntero(clave string) int64 {
	v := sysctlTexto(clave)
	if v == "" {
		return 0
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0
	}
	return n
}
