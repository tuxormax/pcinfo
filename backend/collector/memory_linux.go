//go:build linux

package collector

import (
	"os/exec"
	"strconv"
	"strings"
)

// enrichMemory (Linux) llena ranuras/módulos vía dmidecode (requiere root). Si
// falla, la ficha queda solo con los totales que dio ghw.
func enrichMemory(out *MemoryInfo) {
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
