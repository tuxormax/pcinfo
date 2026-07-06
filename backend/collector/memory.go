package collector

import (
	"strconv"
	"strings"

	"github.com/jaypipes/ghw"
)

func collectMemory() MemoryInfo {
	var out MemoryInfo

	if mem, err := ghw.Memory(); err == nil && mem != nil {
		if mem.TotalPhysicalBytes > 0 {
			out.TotalBytes = mem.TotalPhysicalBytes
		}
		if mem.TotalUsableBytes > 0 {
			out.UsableBytes = mem.TotalUsableBytes
		}
	} else {
		warn("memory", err)
	}

	// Detalle de ranuras/módulos por plataforma (Linux: dmidecode; Windows: WMI).
	// Si falla, la ficha muestra solo los totales.
	enrichMemory(&out)

	// Si ghw no dio el total físico, lo derivamos de los módulos.
	if out.TotalBytes == 0 {
		for _, m := range out.Modules {
			out.TotalBytes += m.SizeBytes
		}
	}
	return out
}

// parseSize convierte "128 GB" / "16384 MB" / "2 TB" a bytes (base 1024, como
// reporta DMI con unidades binarias). Devuelve 0 si no se puede.
func parseSize(s string) int64 {
	fields := strings.Fields(s)
	if len(fields) < 2 {
		return 0
	}
	n, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return 0
	}
	switch strings.ToUpper(fields[1]) {
	case "KB":
		return n * 1024
	case "MB":
		return n * 1024 * 1024
	case "GB":
		return n * 1024 * 1024 * 1024
	case "TB":
		return n * 1024 * 1024 * 1024 * 1024
	}
	return 0
}

// parseSpeed extrae los MHz de "3600 MT/s" o "3200 MHz".
func parseSpeed(s string) int {
	fields := strings.Fields(s)
	if len(fields) < 1 {
		return 0
	}
	n, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0
	}
	return n
}

func isSoldered(formFactor string) bool {
	ff := strings.ToLower(formFactor)
	return strings.Contains(ff, "row of chips") || strings.Contains(ff, "die")
}

// cleanDMI descarta los placeholders típicos de DMI vacío.
func cleanDMI(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "unknown", "not specified", "none", "to be filled by o.e.m.",
		"no module installed", "x.x", "default string", "n/a", "0",
		"00000000", "1234567890":
		return ""
	}
	return strings.TrimSpace(s)
}
