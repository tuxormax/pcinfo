package collector

import (
	"regexp"
	"strings"
	"sync"
	"time"

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
	// Puntero a propósito: en un disco USB diskutil **no manda la clave**, y eso
	// significa "no se sabe", no "no es SSD". Con un bool normal se leería como
	// falso y la ficha diría "HDD" de un disco que igual es de estado sólido.
	SolidState        *bool
	Size              int64
	VirtualOrPhysical string
	SMARTStatus       string
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

// discoDesdeLista arma un disco con SOLO lo que trae `diskutil list`, para
// cuando `diskutil info` no contestó a tiempo. Pasa con discos USB: macOS puede
// quedarse esperando a que alguien conteste un permiso de acceso al volumen y el
// comando no vuelve (ver [[pcinfo-bugs-macos]]).
//
// ⭐ Antes ese disco se saltaba y **desaparecía de la lista**, que es lo peor que
// puede hacer un inventario. Así aparece con lo que se sabe de cierto —cuánto
// mide y cuánto tiene ocupado— y el modelo, el tipo y el bus se quedan VACÍOS en
// vez de inventados. El S.M.A.R.T. se le sigue sondeando: no depende de esto.
func discoDesdeLista(e duEntrada, contenedores []duEntrada) (DiskInfo, bool) {
	if e.Size == 0 {
		return DiskInfo{}, false
	}
	di := DiskInfo{
		Name:            "/dev/" + e.DeviceIdentifier,
		SizeBytes:       e.Size,
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

// modeloDarwin saca el modelo del disco.
//
// MediaName suele ser el nombre comercial completo ("APPLE SSD AP0256Z"), pero
// en los gabinetes USB llega **recortado**: el disco de pruebas daba
// `MediaName = "Tech"` y `IORegistryEntryName = "JMicron Tech Media"`. Por eso,
// cuando el nombre del IORegistry (sin el " Media" del final) CONTIENE al otro y
// es más largo, gana ese: es el mismo dato, completo.
func modeloDarwin(inf duInfo) string {
	medio := strings.TrimSpace(inf.MediaName)
	if strings.EqualFold(medio, "Disk Image") {
		medio = ""
	}
	registro := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(inf.IORegistryEntryName), " Media"))
	if medio == "" {
		return registro
	}
	if registro != "" && len(registro) > len(medio) &&
		strings.Contains(strings.ToLower(registro), strings.ToLower(medio)) {
		return registro
	}
	return medio
}

// tipoYBusDarwin traduce el BusProtocol de diskutil al tipo de disco y al bus
// interno que usa el resto del colector. Se conservan las MISMAS etiquetas de
// tipo que Linux y Windows ("NVMe SSD", "SATA SSD", "HDD"): la concordancia pide
// que una pestaña no cambie de vocabulario según la plataforma.
func tipoYBusDarwin(inf duInfo) (tipo, bus string) {
	p := strings.ToLower(strings.TrimSpace(inf.BusProtocol))
	// ⛔ Tres estados, no dos: sólido, mecánico y **no se sabe**. En los discos
	// USB diskutil no manda la clave, y ahí el tipo se queda VACÍO en vez de
	// afirmar "HDD" — la regla de la Rev 44: lo que no se sabe no se pinta.
	solido := inf.SolidState != nil && *inf.SolidState
	mecanico := inf.SolidState != nil && !*inf.SolidState

	switch {
	case p == "apple fabric", strings.Contains(p, "pci"):
		// El SSD de un Apple Silicon cuelga del propio SoC; es NVMe.
		return "NVMe SSD", "nvme"
	case strings.Contains(p, "ata"): // SATA, Serial ATA, ATA
		if solido {
			return "SATA SSD", "sata"
		}
		if mecanico {
			return "HDD", "sata"
		}
		return "", "sata"
	case strings.Contains(p, "usb"), strings.Contains(p, "thunderbolt"), strings.Contains(p, "firewire"):
		bus := "usb"
		switch {
		case solido:
			return "SSD", bus
		case mecanico:
			return "HDD", bus
		}
		return "", bus
	case strings.Contains(p, "secure digital"), p == "sd":
		return "Tarjeta SD", "mmc"
	default:
		if solido {
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

// plazoStatfs es lo que se espera a que un volumen conteste cuánto ocupa.
const plazoStatfs = 3 * time.Second

// reintentoMontajeLento: cuánto se tarda en volver a preguntarle a un volumen
// que ya se colgó una vez.
const reintentoMontajeLento = 2 * time.Minute

var (
	muMontajes     sync.Mutex
	montajesLentos = map[string]time.Time{}
)

// diskUsagePlazo llama a diskUsage con plazo.
//
// ⛔⛔ `diskUsage` acaba en `statfs`, una llamada al sistema que **no se puede
// cancelar**. Si el volumen no contesta —un disco USB que se va del bus, con el
// cable o la alimentación justos, o un exFAT que quedó sucio— se queda bloqueada
// para siempre, y con ella TODO el inventario de discos. Comprobado el
// 12-sep-2026 con el disco de 2 TB de tuxor: `df "/Volumes/lr 2023"` no volvía y
// la consulta de discos moría de plazo agotado (90 s sin respuesta). Es peor que
// el cuelgue de `diskutil`, porque ahí bastaba un contexto.
//
// Se pregunta en una goroutine aparte y se abandona si tarda. Esa goroutine se
// queda bloqueada hasta que el núcleo devuelva (no hay forma de evitarlo), así
// que el punto de montaje se APUNTA: no se le vuelve a preguntar en un rato. Sin
// eso, cada refresco de la pantalla dejaría otra goroutine colgada.
func diskUsagePlazo(mp string) (used, avail uint64, ok bool) {
	muMontajes.Lock()
	cuando, lento := montajesLentos[mp]
	if lento && time.Since(cuando) < reintentoMontajeLento {
		muMontajes.Unlock()
		return 0, 0, false
	}
	muMontajes.Unlock()

	type resultado struct {
		used, avail uint64
		ok          bool
	}
	ch := make(chan resultado, 1)
	go func() {
		u, a, k := diskUsage(mp)
		ch <- resultado{u, a, k}
	}()

	select {
	case r := <-ch:
		if lento { // contestó: se le quita la marca
			muMontajes.Lock()
			delete(montajesLentos, mp)
			muMontajes.Unlock()
		}
		return r.used, r.avail, r.ok
	case <-time.After(plazoStatfs):
		muMontajes.Lock()
		montajesLentos[mp] = time.Now()
		muMontajes.Unlock()
		warn("statfs", errMontajeLento{mp})
		return 0, 0, false
	}
}

// errMontajeLento es el aviso que queda en el log cuando un volumen no contesta.
type errMontajeLento struct{ mp string }

func (e errMontajeLento) Error() string {
	return "el volumen " + e.mp + " no contestó cuánto espacio ocupa; se deja sin dato"
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
		if used, avail, ok := diskUsagePlazo(p.MountPoint); ok {
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
				if _, avail, ok := diskUsagePlazo(v.MountPoint); ok {
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
