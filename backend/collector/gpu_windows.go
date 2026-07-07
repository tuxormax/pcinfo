//go:build windows

package collector

import (
	"strings"

	"github.com/yusufpapurcu/wmi"
	"golang.org/x/sys/windows/registry"
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
	fillVRAMFromRegistry(cards)
	return cards
}

// fillVRAMFromRegistry lee la VRAM real de cada GPU del registro. WMI
// (AdapterRAM) topa a 4 GB y no sirve; el driver deja el tamaño real en
// HKLM\...\Class\{4d36e968...}\NNNN\HardwareInformation.qwMemorySize (QWORD,
// bytes). Sirve para CUALQUIER fabricante (AMD/Intel/NVIDIA), incluida la
// integrada. Se empareja por DriverDesc == nombre de la GPU. Para NVIDIA,
// nvidia-smi puede refinar luego (mismo dato).
func fillVRAMFromRegistry(cards []GPUCard) {
	const classPath = `SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}`
	base, err := registry.OpenKey(registry.LOCAL_MACHINE, classPath, registry.READ)
	if err != nil {
		warn("registry gpu class", err)
		return
	}
	defer base.Close()
	subs, err := base.ReadSubKeyNames(-1)
	if err != nil {
		return
	}
	for _, n := range subs {
		sub, err := registry.OpenKey(base, n, registry.QUERY_VALUE)
		if err != nil {
			continue
		}
		desc, _, derr := sub.GetStringValue("DriverDesc")
		qw, _, qerr := sub.GetIntegerValue("HardwareInformation.qwMemorySize")
		sub.Close()
		if derr != nil || qerr != nil || qw == 0 {
			continue
		}
		d := strings.TrimSpace(desc)
		for i := range cards {
			if cards[i].MemoryBytes == 0 &&
				strings.EqualFold(strings.TrimSpace(cards[i].Product), d) {
				cards[i].MemoryBytes = int64(qw)
				break
			}
		}
	}
}
