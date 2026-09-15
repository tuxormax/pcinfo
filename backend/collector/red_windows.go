//go:build windows

package collector

import (
	"net"

	"github.com/yusufpapurcu/wmi"
)

// win32IPRouteTable es la ruta por defecto (Destination/Mask = 0.0.0.0),
// leída de la MISMA clase WMI que usan las herramientas de red clásicas.
// Aunque Microsoft la marca como heredada, sigue disponible en Windows 10/11
// y evita depender de PowerShell (Get-NetRoute) solo para esto.
type win32IPRouteTable struct {
	Destination    string
	Mask           string
	NextHop        string
	InterfaceIndex int32
	Metric1        int32
}

// defaultGateway consulta Win32_IP4RouteTable por la ruta 0.0.0.0/0 con menor
// métrica y resuelve el nombre de la interfaz por su índice.
func defaultGateway() (gateway, iface string) {
	var rutas []win32IPRouteTable
	q := "SELECT Destination, Mask, NextHop, InterfaceIndex, Metric1 FROM Win32_IP4RouteTable " +
		"WHERE Destination = '0.0.0.0' AND Mask = '0.0.0.0'"
	if err := wmi.Query(q, &rutas); err != nil {
		warn("wmi IP4RouteTable", err)
		return "", ""
	}

	mejorMetric := int32(-1)
	var idxInterfaz int32 = -1
	for _, r := range rutas {
		if r.NextHop == "" || r.NextHop == "0.0.0.0" {
			continue
		}
		if gateway != "" && r.Metric1 >= mejorMetric {
			continue
		}
		gateway = r.NextHop
		mejorMetric = r.Metric1
		idxInterfaz = r.InterfaceIndex
	}
	if gateway == "" {
		return "", ""
	}

	if ifs, err := net.Interfaces(); err == nil {
		for _, i := range ifs {
			if int32(i.Index) == idxInterfaz {
				iface = i.Name
				break
			}
		}
	}
	return gateway, iface
}
