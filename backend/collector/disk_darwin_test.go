package collector

import (
	"os"
	"path/filepath"
	"testing"
)

// Pruebas del parseo de discos de macOS contra las salidas REALES de la Mac
// mini M4 (testdata/darwin, anonimizadas). ⭐ No llevan etiqueta de plataforma
// a propósito: corren también en Linux, que es donde se trabaja el resto del
// proyecto y donde nadie tiene un Mac delante para comprobar un cambio.

func leeMuestra(t *testing.T, nombre string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "darwin", nombre))
	if err != nil {
		t.Fatalf("no pude leer la muestra %s: %v", nombre, err)
	}
	return b
}

func TestSeparaDiscosDarwin(t *testing.T) {
	fisicos, contenedores, err := separaDiscos(leeMuestra(t, "diskutil_list.plist"))
	if err != nil {
		t.Fatalf("no se pudo parsear diskutil list: %v", err)
	}

	// En el equipo de la muestra: disk0 (el SSD interno) y disk5 (una imagen de
	// disco del simulador de iOS) son "discos"; disk1, disk2, disk3 y disk6 son
	// contenedores APFS y NO deben contarse como hardware.
	ids := map[string]bool{}
	for _, f := range fisicos {
		ids[f.DeviceIdentifier] = true
	}
	if !ids["disk0"] {
		t.Errorf("disk0 (el SSD interno) tenía que salir como disco físico; salieron %v", ids)
	}
	for _, c := range []string{"disk1", "disk2", "disk3", "disk6"} {
		if ids[c] {
			t.Errorf("%s es un contenedor APFS, no un disco físico", c)
		}
	}
	if len(contenedores) != 4 {
		t.Errorf("contenedores APFS: esperaba 4, hubo %d", len(contenedores))
	}
}

func TestDiscoInternoDarwin(t *testing.T) {
	_, contenedores, err := separaDiscos(leeMuestra(t, "diskutil_list.plist"))
	if err != nil {
		t.Fatal(err)
	}
	entrada := duEntrada{DeviceIdentifier: "disk0"}

	di, ok := discoDesdeInfo(entrada, leeMuestra(t, "diskutil_info_disk0.plist"), contenedores)
	if !ok {
		t.Fatal("el SSD interno se descartó y no debía")
	}
	if di.Name != "/dev/disk0" {
		t.Errorf("dispositivo: %q (smartctl necesita /dev/disk0)", di.Name)
	}
	if di.Model != "APPLE SSD AP0256Z" {
		t.Errorf("modelo: %q", di.Model)
	}
	if di.Type != "NVMe SSD" {
		t.Errorf("tipo: %q — el SSD de un Apple Silicon es NVMe", di.Type)
	}
	if di.Port != "Apple Fabric" {
		t.Errorf("«Conectado en»: %q — en un Mac es el bus, tal como lo nombra el sistema", di.Port)
	}
	if di.Removable {
		t.Error("el SSD interno no es de medio extraíble")
	}
	if di.SizeBytes != 251000193024 {
		t.Errorf("tamaño: %d", di.SizeBytes)
	}

	// Lo ocupado sale del CapacityInUse de los volúmenes de los contenedores que
	// viven en este disco. ⚠️ La instantánea disk3s3s1 repite los datos de
	// disk3s3: si se contara, saldrían ~12,5 GB de más.
	// El número es el de la muestra de testdata, no el del equipo hoy: cambia
	// cada vez que se escribe en el disco.
	const ocupadoEsperado = 110741909504
	if di.UsedBytes != ocupadoEsperado {
		t.Errorf("ocupado: %d, esperaba %d (¿se colaron las instantáneas APFS?)",
			di.UsedBytes, ocupadoEsperado)
	}
	if di.UsedBytes > di.SizeBytes {
		t.Error("lo ocupado no puede pasar del tamaño del disco")
	}
}

func TestImagenDeDiscoSeDescartaDarwin(t *testing.T) {
	// disk5 es una imagen de disco (el volumen del simulador de iOS): no es
	// hardware y no debe aparecer en la pestaña Discos.
	_, contenedores, err := separaDiscos(leeMuestra(t, "diskutil_list.plist"))
	if err != nil {
		t.Fatal(err)
	}
	entrada := duEntrada{DeviceIdentifier: "disk5", Size: 18083776000}
	if _, ok := discoDesdeInfo(entrada, leeMuestra(t, "diskutil_info_disk5.plist"), contenedores); ok {
		t.Error("una imagen de disco no es un disco del equipo")
	}
}

func TestDiskutilConErrorDarwin(t *testing.T) {
	// Cuando el disco ya no está, diskutil contesta un plist con Error=true. No
	// debe colarse un disco fantasma (le pasó al disco USB al desconectarse).
	entrada := duEntrada{DeviceIdentifier: "disk4"}
	if di, ok := discoDesdeInfo(entrada, leeMuestra(t, "diskutil_info_disk4.plist"), nil); ok {
		t.Errorf("un disco que ya no existe no debe aparecer: %+v", di)
	}
}

func TestDiscoUSBDarwin(t *testing.T) {
	// Disco USB real: gabinete JMicron de 2 TB (el de tuxor), capturado el
	// 12-sep-2026 con el disco conectado.
	entrada := duEntrada{DeviceIdentifier: "disk4", Size: 2000398934016}
	di, ok := discoDesdeInfo(entrada, leeMuestra(t, "diskutil_info_disk4_usb.plist"), nil)
	if !ok {
		t.Fatal("un disco USB es hardware y tiene que salir en el inventario")
	}
	if di.Name != "/dev/disk4" {
		t.Errorf("dispositivo: %q", di.Name)
	}
	// ⭐ MediaName llega RECORTADO en los gabinetes USB ("Tech"); el nombre del
	// IORegistry trae el completo ("JMicron Tech Media").
	if di.Model != "JMicron Tech" {
		t.Errorf("modelo: %q — se esperaba el nombre completo del IORegistry, no el recortado", di.Model)
	}
	if di.Bus != "usb" || di.Port != "USB" {
		t.Errorf("bus=%q «Conectado en»=%q", di.Bus, di.Port)
	}
	// ⛔ diskutil NO manda SolidState en este disco: el tipo se queda vacío en
	// vez de afirmar "HDD".
	if di.Type != "" {
		t.Errorf("tipo: %q — sin el dato de diskutil no se puede afirmar si es sólido o mecánico", di.Type)
	}
	if di.SizeBytes != 2000398934016 {
		t.Errorf("tamaño: %d", di.SizeBytes)
	}
	// Es un disco externo, pero el MEDIO no es extraíble (no es una memoria USB
	// ni una tarjeta): si se marcara removible, la GUI ni le ofrecería revisar
	// la salud.
	if di.Removable {
		t.Error("un disco en gabinete USB no es «medio extraíble»")
	}
}

func TestDiscoQueNoContestaDarwin(t *testing.T) {
	// Un disco USB puede dejar colgado a `diskutil info` (macOS esperando un
	// permiso). ⛔ Ese disco NO debe desaparecer del inventario: se muestra con
	// lo que dio `diskutil list` y sin inventar modelo, tipo ni bus.
	e := duEntrada{
		DeviceIdentifier: "disk4",
		Content:          "GUID_partition_scheme",
		Size:             2000398934016,
		Partitions: []duParticion{
			{DeviceIdentifier: "disk4s1", Content: "Microsoft Reserved", Size: 134217728},
			{DeviceIdentifier: "disk4s2", Content: "Microsoft Basic Data", Size: 2000263659520,
				MountPoint: "/Volumes/no-existe-en-la-prueba"},
		},
	}
	di, ok := discoDesdeLista(e, nil)
	if !ok {
		t.Fatal("el disco tenía que aparecer aunque diskutil info no contestara")
	}
	if di.Name != "/dev/disk4" {
		t.Errorf("dispositivo: %q — hace falta para poder sondearle el S.M.A.R.T.", di.Name)
	}
	if di.SizeBytes != 2000398934016 {
		t.Errorf("tamaño: %d — lo da la lista, no hace falta el info", di.SizeBytes)
	}
	if di.Model != "" || di.Type != "" || di.Bus != "" || di.Port != "" {
		t.Errorf("sin `diskutil info` no se sabe el modelo/tipo/bus y NO se inventan: %+v", di)
	}
	if di.LifePercentUsed != -1 {
		t.Error("el desgaste tiene que quedar en -1 (desconocido), no en 0")
	}

	// Un disco sin tamaño no es un disco.
	if _, ok := discoDesdeLista(duEntrada{DeviceIdentifier: "disk9"}, nil); ok {
		t.Error("una entrada sin tamaño no debe entrar al inventario")
	}
}

func TestTipoYBusDarwin(t *testing.T) {
	si, no := true, false
	casos := []struct {
		bus    string
		ssd    *bool // nil = diskutil no manda la clave (típico en USB)
		tipo   string
		busInt string
	}{
		{"Apple Fabric", &si, "NVMe SSD", "nvme"},
		{"PCI-Express", &si, "NVMe SSD", "nvme"},
		{"SATA", &si, "SATA SSD", "sata"},
		{"SATA", &no, "HDD", "sata"},
		{"USB", &no, "HDD", "usb"},
		{"USB", &si, "SSD", "usb"},
		{"Thunderbolt", &si, "SSD", "usb"},
		{"Secure Digital", &no, "Tarjeta SD", "mmc"},
		// ⛔ Lo importante: sin el dato, el tipo se queda VACÍO. Antes se leía
		// como "no es sólido" y la ficha afirmaba "HDD" de un disco USB del que
		// no se sabe nada.
		{"USB", nil, "", "usb"},
		{"SATA", nil, "", "sata"},
	}
	for _, c := range casos {
		tipo, bus := tipoYBusDarwin(duInfo{BusProtocol: c.bus, SolidState: c.ssd})
		if tipo != c.tipo || bus != c.busInt {
			t.Errorf("%s (ssd=%v): dio (%q,%q), esperaba (%q,%q)",
				c.bus, ssdTexto(c.ssd), tipo, bus, c.tipo, c.busInt)
		}
	}
}

func ssdTexto(b *bool) string {
	if b == nil {
		return "sin dato"
	}
	if *b {
		return "sólido"
	}
	return "mecánico"
}

func TestInstantaneaAPFSDarwin(t *testing.T) {
	// Los volúmenes normales son "diskNsM"; las instantáneas, "diskNsMsK".
	for _, id := range []string{"disk3s3s1", "disk1s2s3"} {
		if !reInstantanea.MatchString(id) {
			t.Errorf("%s es una instantánea y no se reconoció", id)
		}
	}
	for _, id := range []string{"disk3s3", "disk0s2", "disk10s1"} {
		if reInstantanea.MatchString(id) {
			t.Errorf("%s es un volumen normal, no una instantánea", id)
		}
	}
}
