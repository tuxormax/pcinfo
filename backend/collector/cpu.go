package collector

import (
	"regexp"
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
	// Fallback VM/Windows: sin cpufreq, muchos modelos Intel llevan la frecuencia
	// base embebida en el nombre ("... @ 3.80GHz"). La usamos como BaseMhz.
	if out.BaseMhz == 0 {
		out.BaseMhz = mhzFromModel(out.Model)
	}
	// Windows: la base sale de WMI (Win32_Processor.MaxClockSpeed). El turbo/boost
	// NO lo expone WMI de forma fiable, así que MaxMhz queda en 0 (la GUI oculta
	// la fila "Frecuencia máxima" si es 0). Impl en cpu_windows.go.
	enrichCPU(&out)
	return out
}

// reModelGHz captura "@ 3.80GHz" del nombre del CPU.
var reModelGHz = regexp.MustCompile(`@\s*([0-9]+(?:\.[0-9]+)?)\s*GHz`)

// mhzFromModel extrae la frecuencia embebida en el nombre del modelo (GHz→MHz).
// Devuelve 0 si no la trae (típico en AMD).
func mhzFromModel(model string) float64 {
	if m := reModelGHz.FindStringSubmatch(model); m != nil {
		if ghz, err := strconv.ParseFloat(m[1], 64); err == nil {
			return ghz * 1000.0
		}
	}
	return 0
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
