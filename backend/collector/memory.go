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
	if len(out.Modules) > out.TotalSlots {
		out.TotalSlots = len(out.Modules)
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
