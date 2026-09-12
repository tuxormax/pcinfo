package collector

import (
	"regexp"
	"strings"

	"howett.net/plist"
)

// Parseo de las salidas de `diskutil` en macOS. Vive en un archivo SIN etiqueta
// de plataforma a propósito: así las pruebas del parseo corren también en Linux,
// que es donde está el resto del proyecto (las muestras reales del equipo están
// en testdata/darwin). Lo que ejecuta los comandos es disk_darwin.go.

// duLista es `diskutil list -plist`. Las entradas con APFSPhysicalStores son
// contenedores APFS (discos "sintetizados"): NO son discos físicos, viven dentro
// de una partición de uno. Aun así hacen falta, porque los volúmenes que se
// montan son los suyos y de ahí sale el espacio ocupado.
type duLista struct {
	AllDisksAndPartitions []duEntrada
}

type duEntrada struct {
	DeviceIdentifier   string
	Content            string
	Size               int64
	APFSPhysicalStores []duTienda
	Partitions         []duParticion
	APFSVolumes        []duVolumen
}

type duTienda struct {
	DeviceIdentifier string // p. ej. "disk0s2": en qué partición vive el contenedor
}

type duParticion struct {
	DeviceIdentifier string
	Content          string
	Size             int64
	MountPoint       string
}

type duVolumen struct {
	DeviceIdentifier string
	VolumeName       string
	MountPoint       string
	CapacityInUse    int64
	Size             int64
}

// duInfo es `diskutil info -plist <disco>`, solo los campos que se usan.
type duInfo struct {
	DeviceIdentifier    string
	DeviceNode          string
	MediaName           string
	IORegistryEntryName string
	BusProtocol         string
	Internal            bool
	Removable           bool
	RemovableMedia      bool
	SolidState          bool
	Size                int64
	VirtualOrPhysical   string
	SMARTStatus         string
}

// reInstantanea reconoce una instantánea APFS ("disk3s3s1"): aparece en la lista
// de volúmenes como uno más y repite el espacio ocupado del volumen del que
// cuelga. Sumarla contaría dos veces los mismos datos.
var reInstantanea = regexp.MustCompile(`^disk\d+s\d+s\d+$`)

// separaDiscos parte la salida de `diskutil list -plist` en discos físicos y
// contenedores APFS.
func separaDiscos(salidaLista []byte) (fisicos, contenedores []duEntrada, err error) {
	var lista duLista
	if _, err := plist.Unmarshal(salidaLista, &lista); err != nil {
		return nil, nil, err
	}
	for _, e := range lista.AllDisksAndPartitions {
		if len(e.APFSPhysicalStores) > 0 {
			contenedores = append(contenedores, e)
			continue
		}
		fisicos = append(fisicos, e)
	}
	return fisicos, contenedores, nil
}

// discoDesdeInfo arma un disco con su entrada de la lista y la salida de
// `diskutil info`. Devuelve ok=false cuando no es hardware que interese: una
// imagen de disco (.dmg, los volúmenes del simulador de iOS) o algo sin tamaño.
func discoDesdeInfo(e duEntrada, salidaInfo []byte, contenedores []duEntrada) (DiskInfo, bool) {
	var inf duInfo
	if _, err := plist.Unmarshal(salidaInfo, &inf); err != nil {
		return DiskInfo{}, false
	}
	if strings.EqualFold(inf.VirtualOrPhysical, "Virtual") ||
		strings.EqualFold(inf.BusProtocol, "Disk Image") {
		return DiskInfo{}, false
	}
	tam := inf.Size
	if tam == 0 {
		tam = e.Size
	}
	if tam == 0 {
		return DiskInfo{}, false
	}

	tipo, bus := tipoYBusDarwin(inf)
	di := DiskInfo{
		Name:      nodoDarwin(inf, e.DeviceIdentifier),
		Model:     modeloDarwin(inf),
		SizeBytes: tam,
		Type:      tipo,
		Bus:       bus,
		// "Conectado en" en un Mac es el BUS, no un número de puerto: no hay
		// ranuras ni puertos numerados que consultar.
		Port:            textoBusDarwin(inf.BusProtocol),
		Removable:       inf.RemovableMedia,
		LifePercentUsed: -1,
	}
	usoDiscoDarwin(&di, e, contenedores)
	return di, true
}

// nodoDarwin devuelve el dispositivo tal como lo espera smartctl: "/dev/disk0".
func nodoDarwin(inf duInfo, id string) string {
	if inf.DeviceNode != "" {
		return inf.DeviceNode
	}
	return "/dev/" + id
}

// modeloDarwin: MediaName es el nombre comercial ("APPLE SSD AP0256Z"); si
// viniera vacío se cae al nombre del IORegistry, que trae el mismo texto con
// " Media" al final.
func modeloDarwin(inf duInfo) string {
	if m := strings.TrimSpace(inf.MediaName); m != "" && !strings.EqualFold(m, "Disk Image") {
		return m
	}
	return strings.TrimSpace(strings.TrimSuffix(inf.IORegistryEntryName, " Media"))
}

// tipoYBusDarwin traduce el BusProtocol de diskutil al tipo de disco y al bus
// interno que usa el resto del colector. Se conservan las MISMAS etiquetas de
// tipo que Linux y Windows ("NVMe SSD", "SATA SSD", "HDD"): la concordancia pide
// que una pestaña no cambie de vocabulario según la plataforma.
func tipoYBusDarwin(inf duInfo) (tipo, bus string) {
	p := strings.ToLower(strings.TrimSpace(inf.BusProtocol))
	switch {
	case p == "apple fabric", strings.Contains(p, "pci"):
		// El SSD de un Apple Silicon cuelga del propio SoC; es NVMe.
		return "NVMe SSD", "nvme"
	case strings.Contains(p, "ata"): // SATA, Serial ATA, ATA
		if inf.SolidState {
			return "SATA SSD", "sata"
		}
		return "HDD", "sata"
	case strings.Contains(p, "usb"), strings.Contains(p, "thunderbolt"), strings.Contains(p, "firewire"):
		if inf.SolidState {
			return "SSD", "usb"
		}
		return "HDD", "usb"
	case strings.Contains(p, "secure digital"), p == "sd":
		return "Tarjeta SD", "mmc"
	default:
		if inf.SolidState {
			return "SSD", p
		}
		return "", p
	}
}

// textoBusDarwin es lo que se muestra en "Conectado en". Se respeta el nombre
// que da el sistema ("Apple Fabric", "USB", "Thunderbolt"): es la verdad de
// dónde está enchufado, y en un Mac no hay número de puerto que dar.
func textoBusDarwin(bus string) string {
	return strings.TrimSpace(bus)
}

// usoDiscoDarwin calcula cuánto hay ocupado y cuánto libre en el disco.
//
// ⚠️ En APFS no vale sumar statfs de cada volumen: todos los volúmenes de un
// contenedor comparten el espacio libre y cada uno reporta el del contenedor
// entero, así que sumarlos multiplicaría lo libre por el número de volúmenes.
// Lo ocupado se toma del CapacityInUse de cada volumen (lo que dice diskutil) y
// lo libre, UNA sola vez por contenedor.
func usoDiscoDarwin(di *DiskInfo, disco duEntrada, contenedores []duEntrada) {
	// Particiones normales (exFAT, FAT, HFS+ de un disco externo): statfs directo.
	for _, p := range disco.Partitions {
		if p.MountPoint == "" {
			continue
		}
		if used, avail, ok := diskUsage(p.MountPoint); ok {
			di.UsedBytes += int64(used)
			di.AvailBytes += int64(avail)
		}
	}

	// Contenedores APFS que viven en alguna partición de este disco.
	for _, c := range contenedores {
		if !contenedorEnDisco(c, disco.DeviceIdentifier) {
			continue
		}
		libreTomado := false
		for _, v := range c.APFSVolumes {
			if reInstantanea.MatchString(v.DeviceIdentifier) {
				continue // instantánea: repite lo que ya cuenta su volumen
			}
			di.UsedBytes += v.CapacityInUse
			if !libreTomado && v.MountPoint != "" {
				if _, avail, ok := diskUsage(v.MountPoint); ok {
					di.AvailBytes += int64(avail)
					libreTomado = true
				}
			}
		}
	}
}

// contenedorEnDisco dice si el contenedor APFS c está alojado en el disco id.
// Sus "physical stores" son particiones ("disk0s2"), de ahí el prefijo.
func contenedorEnDisco(c duEntrada, id string) bool {
	for _, t := range c.APFSPhysicalStores {
		if strings.HasPrefix(t.DeviceIdentifier, id+"s") || t.DeviceIdentifier == id {
			return true
		}
	}
	return false
}
