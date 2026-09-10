//go:build linux

package collector

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Ranuras y puertos en Linux. Ver ranuras.go para el porqué de las tres fuentes.
//
// Las ranuras (PCIe / M.2) salen del firmware con `dmidecode -t 9`, que es el
// Type 9 "System Slot Information" del SMBIOS. Requiere root: el backend corre
// como servicio root (ver el .service que instala construir_linux.sh), igual
// que ya hacía para leer las ranuras de RAM.

// ranurasFirmware devuelve las ranuras que declara el firmware, ya traducidas.
func ranurasFirmware() []ExpansionSlot {
	var out []ExpansionSlot
	for _, b := range dmidecodeBlocks("9") {
		s, ok := ranuraDesdeBloque(b)
		if !ok {
			continue
		}
		// El firmware a veces deja el "Current Usage" congelado del arranque
		// anterior. Si la ranura trae dirección de bus y ahí hay un dispositivo
		// PCI de verdad, eso manda: es lo que el sistema ve AHORA.
		if quien, hay := dispositivoEnBus(b["Bus Address"]); hay {
			s.State = "ocupada"
			if s.UsedBy == "" {
				s.UsedBy = quien
			}
		}
		out = append(out, s)
	}
	ordenaRanuras(out)
	return out
}

// ranuraDesdeBloque convierte un bloque de `dmidecode -t 9` en una ranura. Va
// aparte de ranurasFirmware para poder probarla sin dmidecode ni root.
func ranuraDesdeBloque(b map[string]string) (ExpansionSlot, bool) {
	if b["Type"] == "" && b["Current Usage"] == "" {
		return ExpansionSlot{}, false // bloque de otra cosa (cabecera de dmidecode)
	}
	kind, spec := clasificaRanura(b["Type"])
	label := cleanDMI(b["Designation"])
	if label == "" {
		label = spec
	}
	return ExpansionSlot{
		Label:  label,
		Kind:   kind,
		Spec:   spec,
		State:  estadoRanura(b["Current Usage"]),
		Source: "firmware",
	}, true
}

// dispositivoEnBus dice si en una dirección PCI ("0000:01:00.0") hay un
// dispositivo conectado, y qué clase de dispositivo es. El nombre comercial no
// se busca a propósito: haría falta la base pci.ids, y para la ficha basta con
// "tarjeta gráfica" o "controladora de red".
func dispositivoEnBus(addr string) (string, bool) {
	addr = strings.TrimSpace(addr)
	if addr == "" || strings.HasPrefix(addr, "0000:00:00.0") {
		return "", false
	}
	dir := filepath.Join("/sys/bus/pci/devices", addr)
	if _, err := os.Stat(dir); err != nil {
		return "", false
	}
	b, err := os.ReadFile(filepath.Join(dir, "class"))
	if err != nil {
		return "", true
	}
	return clasePCI(strings.TrimSpace(string(b))), true
}

// clasesPCI traduce el código de clase PCI (los dos primeros bytes de
// /sys/bus/pci/devices/*/class) a algo que se entienda en la ficha.
var clasesPCI = map[string]string{
	"0x0100": "controladora SCSI",
	"0x0101": "controladora IDE",
	"0x0104": "controladora RAID",
	"0x0106": "controladora SATA",
	"0x0108": "SSD NVMe",
	"0x0200": "tarjeta de red",
	"0x0280": "tarjeta WiFi",
	"0x0300": "tarjeta gráfica",
	"0x0400": "captura de video",
	"0x0401": "tarjeta de sonido",
	"0x0403": "tarjeta de sonido",
	"0x0c03": "controladora USB",
	"0x0c04": "controladora de fibra",
}

func clasePCI(clase string) string {
	if len(clase) >= 6 {
		if n, ok := clasesPCI[strings.ToLower(clase[:6])]; ok {
			return n
		}
	}
	return "tarjeta de expansión"
}

// reAtaEnRuta encuentra a qué puerto SATA cuelga un dispositivo, a partir de su
// ruta real en sysfs: .../ata3/host2/target2:0:0/2:0:0:0/block/sdb → ata3.
var reAtaEnRuta = regexp.MustCompile(`/ata(\d+)/`)

// puertosSataSistema enumera los puertos SATA que el sistema ve. OJO: son los
// que presenta la CONTROLADORA, no los conectores de la placa — un chipset
// puede exponer 12 y la placa cablear 6. Para la cuenta real de conectores está
// el catálogo (BoardInfo.SataDeclared).
func puertosSataSistema() []SataPort {
	entradas, err := os.ReadDir("/sys/class/ata_port")
	if err != nil {
		warn("ata_port", err)
		return nil
	}
	var nums []int
	for _, e := range entradas {
		if n, err := strconv.Atoi(strings.TrimPrefix(e.Name(), "ata")); err == nil {
			nums = append(nums, n)
		}
	}
	sort.Ints(nums)
	out := make([]SataPort, 0, len(nums))
	for _, n := range nums {
		out = append(out, SataPort{Label: etiquetaSata(n)})
	}
	return out
}

func etiquetaSata(n int) string { return "SATA " + strconv.Itoa(n) }

// enrichPuertosDiscos escribe en cada disco DÓNDE está enchufado, siguiendo su
// ruta real en sysfs. Es un dato del sistema: no depende del firmware ni del
// catálogo, así que sale igual en cualquier placa.
func enrichPuertosDiscos(disks []DiskInfo) {
	for i := range disks {
		nombre := strings.TrimPrefix(disks[i].Name, "/dev/")
		if nombre == "" {
			continue
		}
		ruta, err := filepath.EvalSymlinks(filepath.Join("/sys/block", nombre))
		if err != nil {
			continue
		}
		disks[i].Port = puertoDesdeRuta(ruta, nombre)
	}
}

// puertoDesdeRuta traduce la ruta de sysfs al sitio físico donde está el disco.
// El orden importa: un disco USB también cuelga de un "host" SCSI, así que USB
// se comprueba antes que SATA.
func puertoDesdeRuta(ruta, nombre string) string {
	switch {
	case strings.Contains(ruta, "/usb"):
		return "USB"
	case strings.HasPrefix(nombre, "nvme"):
		return "M.2 / PCIe (" + nombre + ")"
	case strings.HasPrefix(nombre, "mmcblk"):
		return "Lector de tarjetas"
	}
	if m := reAtaEnRuta.FindStringSubmatch(ruta + "/"); m != nil {
		n, _ := strconv.Atoi(m[1])
		return etiquetaSata(n)
	}
	return ""
}
