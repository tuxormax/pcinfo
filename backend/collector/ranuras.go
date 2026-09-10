package collector

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Ranuras de expansión y puertos SATA de la placa.
//
// Por qué existe este archivo: el inventario decía qué discos y qué tarjetas
// están PUESTOS, pero no qué sitios hay para poner más. En un taller la
// pregunta es justo esa —"¿le cabe otro disco?", "¿tiene M.2?", "¿queda un
// PCIe libre?"— y respondida a ojo obliga a abrir el gabinete.
//
// Tres fuentes, en este orden de confianza (el mismo criterio que las ranuras
// de RAM, ver aplicaCatalogo en memory.go):
//
//  1. CATÁLOGO de placas (placas.json) → hoja de datos del fabricante. Es lo
//     único que sabe cuántos conectores SATA trae LA PLACA: el chipset presenta
//     más puertos de los que se cablean (un equipo de pruebas expone 12 puertos
//     ata con 6 conectores en la placa).
//  2. FIRMWARE (SMBIOS Type 9) → declara las ranuras y si están en uso. Fiable
//     para PCIe/M.2 en la mayoría de placas, pero hay firmware que las omite.
//  3. SISTEMA (sysfs / WMI) → qué hay conectado AHORA. Es la única fuente que
//     no miente sobre la ocupación, así que manda sobre el firmware para eso.
func enrichBoardPorts(board *BoardInfo, disks []DiskInfo, gpu GPUInfo) {
	fw := ranurasFirmware()
	sata := puertosSataSistema()

	// Ocupación real de los puertos SATA: qué disco cuelga de cada uno.
	for i := range sata {
		for _, d := range disks {
			if d.Port != "" && d.Port == sata[i].Label {
				sata[i].Used = true
				sata[i].UsedBy = etiquetaDisco(d)
			}
		}
	}
	board.SataPorts = sata
	for _, d := range disks {
		if d.Bus == "sata" && !d.Removable {
			board.SataUsed++
		}
	}

	spec, hayCatalogo := buscaPlaca(board.Vendor, board.Product)

	switch {
	case hayCatalogo && len(spec.ranurasCatalogo()) > 0:
		board.Slots = fusionaConCatalogo(spec.ranurasCatalogo(), fw)
		board.PortsSource = "catalogo"
	case len(fw) > 0:
		board.Slots = fw
		board.PortsSource = "firmware"
	}
	if hayCatalogo {
		board.PortsNote = spec.Notas
	}
	if hayCatalogo && spec.Sata > 0 {
		board.SataDeclared = spec.Sata
		if board.PortsSource == "" {
			board.PortsSource = "catalogo"
		}
	}

	marcaOcupacionReal(board.Slots, disks, gpu)
}

// ranurasCatalogo devuelve las ranuras declaradas en la hoja de datos, ya como
// ExpansionSlot (sin estado: el catálogo dice qué TIENE la placa, no qué hay
// puesto).
func (p PlacaSpec) ranurasCatalogo() []ExpansionSlot {
	var out []ExpansionSlot
	for _, r := range p.PCIe {
		out = append(out, ExpansionSlot{Label: r.Label, Kind: "pcie", Spec: r.Spec, Source: "catalogo"})
	}
	for _, r := range p.M2 {
		kind := "m2"
		if r.WiFi {
			kind = "m2wifi"
		}
		out = append(out, ExpansionSlot{Label: r.Label, Kind: kind, Spec: r.Spec, Source: "catalogo"})
	}
	return out
}

// fusionaConCatalogo toma las ranuras del catálogo (la lista buena) y les pega
// el estado que declaró el firmware. Casa primero por etiqueta normalizada y,
// si no hay coincidencia, por posición dentro del mismo tipo de ranura — que es
// lo que ocurre cuando el firmware nombra las ranuras a su manera ("PCIe Slot
// 1" contra el "PCIEX16_1" de la serigrafía). Si tampoco cuadra, la ranura
// queda SIN estado (mejor eso que inventarlo).
func fusionaConCatalogo(cat, fw []ExpansionSlot) []ExpansionSlot {
	usada := make([]bool, len(fw))

	// 1ª pasada: por etiqueta.
	for i := range cat {
		for j := range fw {
			if usada[j] || fw[j].State == "" {
				continue
			}
			if normalizaEtiqueta(cat[i].Label) == normalizaEtiqueta(fw[j].Label) {
				cat[i].State, cat[i].UsedBy = fw[j].State, fw[j].UsedBy
				usada[j] = true
				break
			}
		}
	}
	// 2ª pasada: por orden dentro del mismo tipo.
	for i := range cat {
		if cat[i].State != "" {
			continue
		}
		for j := range fw {
			if usada[j] || fw[j].State == "" || fw[j].Kind != cat[i].Kind {
				continue
			}
			cat[i].State, cat[i].UsedBy = fw[j].State, fw[j].UsedBy
			usada[j] = true
			break
		}
	}
	return cat
}

// marcaOcupacionReal corrige el estado con lo que el sistema ve DE VERDAD, que
// manda sobre el firmware: un SSD NVMe conectado ocupa una ranura M.2 aunque el
// firmware la declare disponible (pasa en placas que no actualizan el Type 9), y
// una gráfica dedicada ocupa la PCIe x16.
func marcaOcupacionReal(slots []ExpansionSlot, disks []DiskInfo, gpu GPUInfo) {
	// Discos en M.2 (NVMe). Van a las ranuras M.2 de almacenamiento, en orden.
	var enM2 []DiskInfo
	for _, d := range disks {
		if d.Bus == "nvme" && !d.Removable {
			enM2 = append(enM2, d)
		}
	}
	i := 0
	for s := range slots {
		if slots[s].Kind != "m2" || i >= len(enM2) {
			continue
		}
		slots[s].State = "ocupada"
		slots[s].UsedBy = etiquetaDisco(enM2[i])
		i++
	}

	// Gráfica dedicada → la primera PCIe x16 (la de la tarjeta).
	for _, c := range gpu.Cards {
		if esIntegrada(c) {
			continue
		}
		for s := range slots {
			if slots[s].Kind == "pcie" && strings.Contains(slots[s].Spec, "x16") &&
				slots[s].UsedBy == "" {
				slots[s].State = "ocupada"
				slots[s].UsedBy = strings.TrimSpace(c.Vendor + " " + c.Product)
				break
			}
		}
		break
	}
}

// puertoPorBus es la etiqueta de respaldo del sitio donde está un disco cuando
// el sistema no da el número de puerto (es el caso de Windows). Dice el tipo de
// conexión, que es la mitad del dato, en vez de dejar el campo vacío.
func puertoPorBus(bus string) string {
	switch bus {
	case "sata":
		return "SATA"
	case "nvme":
		return "M.2 / PCIe"
	case "usb":
		return "USB"
	case "mmc":
		return "Lector de tarjetas"
	}
	return ""
}

// asignaPuertos escribe en cada disco dónde está enchufado: primero lo que sepa
// el sistema (número de puerto), y si no, la etiqueta genérica de su bus.
func asignaPuertos(disks []DiskInfo) {
	enrichPuertosDiscos(disks)
	for i := range disks {
		if disks[i].Port == "" {
			disks[i].Port = puertoPorBus(disks[i].Bus)
		}
	}
}

// etiquetaDisco arma el "quién ocupa esto" de un disco: dispositivo y modelo.
func etiquetaDisco(d DiskInfo) string {
	if d.Model == "" {
		return d.Name
	}
	if d.Name == "" {
		return d.Model
	}
	return d.Name + " — " + d.Model
}

var reNoAlfanum = regexp.MustCompile(`[^A-Z0-9]`)

// normalizaEtiqueta deja "M.2_1" y "M2 1" en la misma forma para poder casar la
// serigrafía del catálogo con el nombre que use el firmware.
func normalizaEtiqueta(s string) string {
	return reNoAlfanum.ReplaceAllString(strings.ToUpper(s), "")
}

// --- Traducción de lo que dice el firmware (SMBIOS Type 9) -----------------

// reGenPCIe saca la generación de un "PCI Express 3", "PCI Express Gen 4"...
var reGenPCIe = regexp.MustCompile(`(?i)PCI\s*EXPRESS\s*(?:GEN)?\s*([1-6])`)

// reAncho saca el ancho de "x16 PCI Express 3" o "PCI Express 3 x4".
var reAncho = regexp.MustCompile(`(?i)(?:^|\s)x(1|2|4|8|16|32)(?:\s|$)`)

// clasificaRanura traduce el "Type" del SMBIOS a (kind, spec legible). El
// firmware lo escribe en su jerga —"x16 PCI Express 3", "M.2 Socket 3"— y en la
// ficha tiene que leerse como en la caja de la placa: "PCIe 3.0 x16".
func clasificaRanura(tipo string) (kind, spec string) {
	t := strings.TrimSpace(tipo)
	u := strings.ToUpper(t)

	if strings.Contains(u, "M.2") || strings.Contains(u, "M2 SOCKET") {
		// Los "Socket 1-DP" / "1-SD" son los de módulo WiFi, no de disco:
		// contarlos como sitio para un SSD sería mandar a comprar uno que no
		// entra (llave A/E contra llave M).
		switch {
		case strings.Contains(u, "SOCKET 1"):
			return "m2wifi", "M.2 llave A/E (módulo WiFi)"
		case strings.Contains(u, "SOCKET 2"):
			return "m2", "M.2 llave B (SATA / PCIe x2)"
		case strings.Contains(u, "SOCKET 3"):
			return "m2", "M.2 llave M (PCIe x4 / NVMe)"
		}
		return "m2", "M.2"
	}

	if strings.Contains(u, "PCI EXPRESS") {
		partes := []string{"PCIe"}
		if m := reGenPCIe.FindStringSubmatch(u); m != nil {
			partes = append(partes, m[1]+".0")
		}
		if m := reAncho.FindStringSubmatch(u); m != nil {
			partes = append(partes, "x"+m[1])
		}
		if strings.Contains(u, "MINI") {
			return "pcie", "Mini PCIe"
		}
		return "pcie", strings.Join(partes, " ")
	}

	switch {
	case strings.Contains(u, "AGP"):
		return "otra", t
	case strings.Contains(u, "PCI"):
		return "pci", "PCI"
	}
	return "otra", t
}

// estadoRanura traduce el "Current Usage" del SMBIOS. "Unknown"/"Unavailable"
// se quedan en "" (no se sabe), nunca en "libre".
func estadoRanura(uso string) string {
	switch strings.ToLower(strings.TrimSpace(uso)) {
	case "in use", "in-use":
		return "ocupada"
	case "available":
		return "libre"
	}
	return ""
}

// ordenaRanuras deja las ranuras en un orden estable y legible: primero las
// PCIe (de mayor ancho a menor), luego las M.2 de disco, luego las de WiFi y el
// resto. Sin esto el orden es el del firmware, que es arbitrario.
func ordenaRanuras(s []ExpansionSlot) {
	peso := map[string]int{"pcie": 0, "m2": 1, "m2wifi": 2, "pci": 3, "otra": 4}
	sort.SliceStable(s, func(i, j int) bool {
		if peso[s[i].Kind] != peso[s[j].Kind] {
			return peso[s[i].Kind] < peso[s[j].Kind]
		}
		return anchoPCIe(s[i].Spec) > anchoPCIe(s[j].Spec)
	})
}

// anchoPCIe devuelve el número de carriles de un spec ("PCIe 3.0 x16" → 16).
func anchoPCIe(spec string) int {
	if m := reAncho.FindStringSubmatch(spec); m != nil {
		n := 0
		fmt.Sscanf(m[1], "%d", &n)
		return n
	}
	return 0
}

// esIntegrada distingue la gráfica del propio procesador de una tarjeta
// dedicada: solo la dedicada ocupa una ranura PCIe.
//
// ⚠️ La MISMA lista vive en la GUI (_gpuKind en dashboard_page.dart y en
// report.dart, que rotulan la ficha "Integrada"/"Dedicada"). Si se agrega una
// familia aquí, agregarla también allá o la ficha y las ranuras se
// contradicen en pantalla.
func esIntegrada(c GPUCard) bool {
	v := strings.ToLower(c.Vendor)
	p := strings.ToLower(c.Product)
	p = strings.NewReplacer("(tm)", "", "(r)", "").Replace(p)
	if strings.Contains(v, "intel") {
		return true
	}
	for _, f := range []string{"uhd", "iris", "vega", "radeon graphics", "raphael",
		"cezanne", "renoir", "phoenix", "rembrandt", "hawk point"} {
		if strings.Contains(p, f) {
			return true
		}
	}
	return false
}
