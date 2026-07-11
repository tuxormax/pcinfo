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
	// Tipo 16: capacidad máxima soportada por la placa. Su "Number Of Devices"
	// NO es fiable (mucho firmware lo declara genérico: la Gigabyte A520M K V2
	// dice 4 con 2 ranuras físicas), así que solo lo usamos de respaldo.
	declaradas := 0
	if blocks := dmidecodeBlocks("16"); len(blocks) > 0 {
		for _, b := range blocks {
			if n, err := strconv.Atoi(b["Number Of Devices"]); err == nil && n > declaradas {
				declaradas = n
			}
			if cap := parseSize(b["Maximum Capacity"]); cap > out.MaxCapacityBytes {
				out.MaxCapacityBytes = cap
			}
		}
	}

	// Tipo 17: un registro por ranura física, ocupada o no. Contarlos es la
	// cuenta fiable de ranuras (lo que hacen CPU-Z/HWiNFO).
	blocks17 := dmidecodeBlocks("17")
	out.TotalSlots = len(blocks17)
	if out.TotalSlots == 0 {
		out.TotalSlots = declaradas
	}
	out.MaxCapacityBytes = ajustaMaxCapacidad(out.MaxCapacityBytes, declaradas, out.TotalSlots)

	for _, b := range blocks17 {
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
