//go:build windows

package collector

import (
	"strings"

	"github.com/yusufpapurcu/wmi"
)

type win32ComputerSystem struct {
	Manufacturer string
	Model        string
}

// equipoActual devuelve «Fabricante Modelo» de la máquina ("HP HP Elite SFF 805
// G9 Desktop PC"), o "" si no se pudo leer. Lo usa el catálogo de controladores
// del fabricante para las filas que son de un modelo concreto.
func equipoActual() string {
	var cs []win32ComputerSystem
	if err := wmi.Query("SELECT Manufacturer, Model FROM Win32_ComputerSystem", &cs); err != nil || len(cs) == 0 {
		warn("wmi equipo", err)
		return ""
	}
	return strings.TrimSpace(cs[0].Manufacturer + " " + cs[0].Model)
}
