package collector

import (
	"strconv"
	"strings"

	"github.com/jaypipes/ghw"
)

func collectCPU() CPUInfo {
	var out CPUInfo
	info, err := ghw.CPU()
	if err != nil || info == nil {
		warn("cpu", err)
		return out
	}

	out.Cores = int(info.TotalCores)
	out.Threads = int(info.TotalThreads)
	if len(info.Processors) > 0 {
		p := info.Processors[0]
		out.Vendor = p.Vendor
		out.Model = strings.TrimSpace(p.Model)
		// Si los totales vienen en cero, sumamos por procesador.
		if out.Cores == 0 || out.Threads == 0 {
			var c, t int
			for _, pr := range info.Processors {
				c += int(pr.NumCores)
				t += int(pr.NumThreads)
			}
			if out.Cores == 0 {
				out.Cores = c
			}
			if out.Threads == 0 {
				out.Threads = t
			}
		}
	}

	out.BaseMhz = cpuFreqMhz("base_frequency", "scaling_min_freq")
	out.MaxMhz = cpuFreqMhz("cpuinfo_max_freq", "scaling_max_freq")
	return out
}

// cpuFreqMhz lee la primera frecuencia disponible (en kHz) de cpufreq de cpu0 y
// la convierte a MHz. Devuelve 0 si no existe (gap conocido en VMs/Windows).
func cpuFreqMhz(candidates ...string) float64 {
	const base = "/sys/devices/system/cpu/cpu0/cpufreq/"
	for _, name := range candidates {
		if raw := readTrim(base + name); raw != "" {
			if khz, err := strconv.ParseFloat(raw, 64); err == nil && khz > 0 {
				return khz / 1000.0
			}
		}
	}
	return 0
}
