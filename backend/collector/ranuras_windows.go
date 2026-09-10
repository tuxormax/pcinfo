//go:build windows

package collector

import "strconv"

// Ranuras y puertos en Windows.
//
// Las ranuras salen de la MISMA tabla SMBIOS que en Linux (Type 9), pero aquí
// se lee cruda con GetSystemFirmwareTable (ver smbios_windows.go) y hay que
// interpretar los códigos a mano, porque no existe dmidecode. Para no duplicar
// criterio, los códigos se traducen al MISMO texto que imprime dmidecode ("x16
// PCI Express 3", "M.2 Socket 3") y de ahí en adelante manda clasificaRanura,
// que es común a los dos sistemas.

// Códigos del campo "Slot Type" (offset 0x05) del SMBIOS Type 9.
const (
	slotPCI     = 0x06
	slotM2Dp    = 0x13 // M.2 Socket 1-DP (llave A) — módulo WiFi
	slotM2Sd    = 0x14 // M.2 Socket 1-SD (llave E) — módulo WiFi
	slotM2Sock2 = 0x15 // M.2 Socket 2 (llave B-M)
	slotM2Sock3 = 0x16 // M.2 Socket 3 (llave M) — el de los SSD NVMe
)

// basesPCIe son los códigos donde arranca cada generación de PCI Express. En
// cada bloque los códigos siguen SIEMPRE el mismo orden: base, x1, x2, x4, x8,
// x16 (así lo define la especificación SMBIOS desde la 2.6).
var basesPCIe = []struct {
	base byte
	gen  int
}{
	{0xA5, 1}, {0xAB, 2}, {0xB1, 3}, {0xB8, 4}, {0xBE, 5},
}

// anchosPCIe es el orden de anchos dentro de cada bloque de generación.
var anchosPCIe = []string{"", "x1", "x2", "x4", "x8", "x16"}

// anchosBus traduce el campo "Slot Data Bus Width" (offset 0x06), que es de
// donde sale el ancho cuando el tipo de ranura es el genérico "PCI Express".
var anchosBus = map[byte]string{
	0x08: "x1", 0x09: "x2", 0x0A: "x4", 0x0B: "x8", 0x0C: "x12",
	0x0D: "x16", 0x0E: "x32",
}

// textoTipoRanura arma el texto estilo dmidecode del tipo de ranura.
func textoTipoRanura(tipo, ancho byte) string {
	switch tipo {
	case slotPCI:
		return "PCI"
	case slotM2Dp:
		return "M.2 Socket 1-DP"
	case slotM2Sd:
		return "M.2 Socket 1-SD"
	case slotM2Sock2:
		return "M.2 Socket 2"
	case slotM2Sock3:
		return "M.2 Socket 3"
	}
	for _, b := range basesPCIe {
		if tipo < b.base || int(tipo-b.base) >= len(anchosPCIe) {
			continue
		}
		gen := "PCI Express"
		if b.gen > 1 {
			gen = "PCI Express Gen " + strconv.Itoa(b.gen)
		}
		if w := anchosPCIe[tipo-b.base]; w != "" {
			return w + " " + gen
		}
		if w, ok := anchosBus[ancho]; ok { // tipo genérico: el ancho va aparte
			return w + " " + gen
		}
		return gen
	}
	return ""
}

// textoUsoRanura traduce el "Current Usage" (offset 0x07) al texto de dmidecode.
func textoUsoRanura(uso byte) string {
	switch uso {
	case 0x03:
		return "Available"
	case 0x04:
		return "In Use"
	}
	return "Unknown"
}

// ranurasFirmware lee el Type 9 de la tabla SMBIOS cruda.
func ranurasFirmware() []ExpansionSlot {
	var out []ExpansionSlot
	for _, t := range smbiosTables() {
		if t.Type != 9 || len(t.Data) < 0x0C {
			continue
		}
		tipo := textoTipoRanura(t.Data[0x05], t.Data[0x06])
		if tipo == "" {
			continue // ranura de un tipo que no interesa (ISA, MXM, propietaria)
		}
		kind, spec := clasificaRanura(tipo)
		label := cleanDMI(t.str(0x04))
		if label == "" {
			label = spec
		}
		out = append(out, ExpansionSlot{
			Label:  label,
			Kind:   kind,
			Spec:   spec,
			State:  estadoRanura(textoUsoRanura(t.Data[0x07])),
			Source: "firmware",
		})
	}
	ordenaRanuras(out)
	return out
}

// puertosSataSistema: en Windows no hay un equivalente a /sys/class/ata_port que
// liste los puertos de la controladora, ocupados o no. Se devuelve nada a
// propósito: la cuenta de conectores sale del catálogo de placas y la de
// ocupados, de los discos SATA detectados (ver enrichBoardPorts). Inventar una
// cuenta desde el número de discos diría "1 puerto SATA" en una placa con 6.
func puertosSataSistema() []SataPort { return nil }

// enrichPuertosDiscos: Windows no expone el número de puerto SATA de cada disco
// por una vía estable (el "SCSIPort" de WMI es del adaptador, no del conector
// serigrafiado). Cada disco se queda con la etiqueta genérica de su bus, que la
// pone puertoPorBus.
func enrichPuertosDiscos([]DiskInfo) {}
