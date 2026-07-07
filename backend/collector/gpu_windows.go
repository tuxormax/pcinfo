//go:build windows

package collector

import (
	"strings"

	"github.com/yusufpapurcu/wmi"
)

// win32VideoController mapea Win32_VideoController (una GPU cada fila).
type win32VideoController struct {
	Name                   string
	AdapterCompatibility   string // fabricante ("Advanced Micro Devices, Inc.", "NVIDIA")
	DriverVersion          string
	ConfigManagerErrorCode uint32 // 0 = OK; ≠0 = deshabilitada/con problema
}

// windowsGPUCards enumera las GPU vía WMI. Es más fiable que ghw en Windows:
// siempre trae Name (modelo) y DriverVersion, incluido el iGPU AMD. Descarta los
// adaptadores virtuales/de respaldo (Basic Display/Render, Remote Desktop) y los
// deshabilitados. La VRAM NO se toma de aquí (AdapterRAM está topado a 4 GB); la
// real de NVIDIA la pone luego nvidia-smi.
func windowsGPUCards() []GPUCard {
	var ctrls []win32VideoController
	q := "SELECT Name, AdapterCompatibility, DriverVersion, ConfigManagerErrorCode FROM Win32_VideoController"
	if err := wmi.Query(q, &ctrls); err != nil {
		warn("wmi VideoController", err)
		return []GPUCard{}
	}
	cards := []GPUCard{}
	for _, c := range ctrls {
		name := strings.TrimSpace(c.Name)
		if name == "" || c.ConfigManagerErrorCode != 0 {
			continue
		}
		low := strings.ToLower(name)
		if strings.Contains(low, "basic display") ||
			strings.Contains(low, "basic render") ||
			strings.Contains(low, "remote desktop") ||
			strings.Contains(low, "mirror") {
			continue
		}
		cards = append(cards, GPUCard{
			Vendor:  strings.TrimSpace(c.AdapterCompatibility),
			Product: name,
			Driver:  strings.TrimSpace(c.DriverVersion),
		})
	}
	return cards
}
