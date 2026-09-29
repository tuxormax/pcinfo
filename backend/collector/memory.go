package collector

import (
	"strconv"
	"strings"

	"github.com/jaypipes/ghw"
)

func collectMemory(board BoardInfo) MemoryInfo {
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
	marcaSoldadas(&out)

	// El catálogo de placas manda sobre el firmware: es un dato verificado
	// contra la hoja de datos del fabricante.
	aplicaCatalogo(&out, board)

	// Si ghw no dio el total físico, lo derivamos de los módulos.
	if out.TotalBytes == 0 {
		for _, m := range out.Modules {
			out.TotalBytes += m.SizeBytes
		}
	}

	// Nunca menos ranuras que módulos instalados.
	if n := modulosEnRanura(out.Modules); n > out.TotalSlots {
		out.TotalSlots = n
	}
	return out
}

// aplicaCatalogo sobrescribe ranuras y capacidad máxima con la ficha verificada
// de la placa, si está en el catálogo (ver catalogo.go). Orden de confianza para
// estos dos datos, de mayor a menor:
//
//  1. catálogo de placas   → hoja de datos del fabricante (dato real)
//  2. SMBIOS Type 17       → un registro por ranura física (cuenta fiable)
//  3. ajustaMaxCapacidad() → deshace la cuenta inflada del firmware
//  4. SMBIOS Type 16       → lo que declara el firmware (miente seguido)
func aplicaCatalogo(out *MemoryInfo, board BoardInfo) {
	p, ok := buscaPlaca(board.Vendor, board.Product)
	if !ok {
		return // sin ficha verificada: quedan los datos del firmware (SlotsVerified=false)
	}
	if p.Ranuras > 0 {
		out.TotalSlots = p.Ranuras
	}
	if p.MaxGiB > 0 {
		out.MaxCapacityBytes = int64(p.MaxGiB) << 30
	}
	// Marca el dato como verificado solo si el catálogo aportó ranuras o tope.
	if p.Ranuras > 0 || p.MaxGiB > 0 {
		out.SlotsVerified = true
	}
}

// ajustaMaxCapacidad corrige la capacidad máxima del SMBIOS Type 16 cuando ese
// mismo registro miente en el número de ranuras. El firmware declara la máxima
// PARA LAS RANURAS QUE DICE TENER, así que si dice 4 ranuras / 128 GiB pero la
// placa tiene 2 físicas (registros Type 17), el tope real es por ranura ×
// ranuras reales = 64 GiB. Caso Gigabyte A520M K V2.
func ajustaMaxCapacidad(maxBytes int64, declaradas, reales int) int64 {
	if maxBytes <= 0 || declaradas <= 0 || reales <= 0 || reales >= declaradas {
		return maxBytes
	}
	return maxBytes / int64(declaradas) * int64(reales)
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

// formatoSoldado es el formato con el que se etiqueta la RAM soldada.
const formatoSoldado = "Row Of Chips"

// formatoDesconocido dice si el firmware no declaró el tamaño del módulo.
func formatoDesconocido(ff string) bool {
	switch strings.ToLower(strings.TrimSpace(ff)) {
	case "", "unknown", "other", "desconocido":
		return true
	}
	return false
}

// modulosEnRanura cuenta los módulos que sí van en una ranura (no soldados).
func modulosEnRanura(mods []MemModule) int {
	n := 0
	for _, m := range mods {
		if !isSoldered(m.FormFactor) {
			n++
		}
	}
	return n
}

// marcaSoldadas detecta la RAM soldada que el firmware no declara como "Row of
// chips" (caso Lenovo: un SODIMM real + 4 GiB soldados sin formato). Si hay al
// menos un módulo en ranura (DIMM/SODIMM) y otro sin formato, el segundo es
// soldado: no cuenta como ranura. Soldered queda en true solo si TODA la RAM es
// soldada; la mezcla se ve por SolderedBytes.
func marcaSoldadas(out *MemoryInfo) {
	if len(out.Modules) == 0 {
		return
	}
	enRanura := false
	for _, m := range out.Modules {
		if !formatoDesconocido(m.FormFactor) && !isSoldered(m.FormFactor) {
			enRanura = true
		}
	}
	if enRanura {
		for i := range out.Modules {
			if formatoDesconocido(out.Modules[i].FormFactor) {
				out.Modules[i].FormFactor = formatoSoldado
			}
		}
	}
	out.SolderedBytes = 0
	nSold := 0
	for _, m := range out.Modules {
		if isSoldered(m.FormFactor) {
			out.SolderedBytes += m.SizeBytes
			nSold++
		}
	}
	out.Soldered = nSold == len(out.Modules)
	// Mezcla: los soldados también ocupan un registro Type 17; se descuentan.
	if nSold > 0 && !out.Soldered && out.TotalSlots >= nSold {
		out.TotalSlots -= nSold
	}
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
