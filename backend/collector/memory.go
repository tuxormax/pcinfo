package collector

import (
	"os/exec"
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

	// Detalle de ranuras/módulos vía dmidecode (requiere root). Si falla, la
	// ficha muestra solo los totales.
	enrichMemoryFromDMI(&out)

	// Si ghw no dio el total físico, lo derivamos de los módulos.
	if out.TotalBytes == 0 {
		for _, m := range out.Modules {
			out.TotalBytes += m.SizeBytes
		}
	}
	return out
}

func enrichMemoryFromDMI(out *MemoryInfo) {
	// Tipo 16: arreglo físico → ranuras totales y capacidad máxima.
	if blocks := dmidecodeBlocks("16"); len(blocks) > 0 {
		for _, b := range blocks {
			if n, err := strconv.Atoi(b["Number Of Devices"]); err == nil && n > out.TotalSlots {
				out.TotalSlots = n
			}
			if cap := parseSize(b["Maximum Capacity"]); cap > out.MaxCapacityBytes {
				out.MaxCapacityBytes = cap
			}
		}
	}

	// Tipo 17: cada dispositivo de memoria (solo las ranuras ocupadas).
	for _, b := range dmidecodeBlocks("17") {
		size := parseSize(b["Size"])
		if size <= 0 { // "No Module Installed"
			continue
		}
		ff := b["Form Factor"]
		mod := MemModule{
			Label:      firstNonEmpty(b["Locator"], b["Bank Locator"]),
			Location:   b["Bank Locator"],
			Vendor:     cleanDMI(b["Manufacturer"]),
			SizeBytes:  size,
			Type:       cleanDMI(b["Type"]),
			SpeedMhz:   parseSpeed(firstNonEmpty(b["Configured Memory Speed"], b["Speed"])),
			FormFactor: ff,
		}
		out.Modules = append(out.Modules, mod)
		if isSoldered(ff) {
			out.Soldered = true
		}
	}
}

// dmidecodeBlocks ejecuta `dmidecode -t <tipo>` y devuelve cada handle como un
// mapa clave→valor (solo líneas "Clave: Valor" de primer nivel).
func dmidecodeBlocks(dtype string) []map[string]string {
	out, err := exec.Command("dmidecode", "-t", dtype).Output()
	if err != nil {
		warn("dmidecode", err)
		return nil
	}
	var blocks []map[string]string
	var cur map[string]string
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "Handle ") {
			if cur != nil && len(cur) > 0 {
				blocks = append(blocks, cur)
			}
			cur = map[string]string{}
			continue
		}
		if cur == nil {
			continue
		}
		// Solo pares "  Clave: Valor" (una indentación, sin sub-listas).
		trimmed := strings.TrimSpace(line)
		if k, v, ok := strings.Cut(trimmed, ": "); ok {
			cur[k] = strings.TrimSpace(v)
		}
	}
	if cur != nil && len(cur) > 0 {
		blocks = append(blocks, cur)
	}
	return blocks
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
