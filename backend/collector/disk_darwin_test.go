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

func TestTipoYBusDarwin(t *testing.T) {
	casos := []struct {
		bus    string
		ssd    bool
		tipo   string
		busInt string
	}{
		{"Apple Fabric", true, "NVMe SSD", "nvme"},
		{"PCI-Express", true, "NVMe SSD", "nvme"},
		{"SATA", true, "SATA SSD", "sata"},
		{"SATA", false, "HDD", "sata"},
		{"USB", false, "HDD", "usb"},
		{"USB", true, "SSD", "usb"},
		{"Thunderbolt", true, "SSD", "usb"},
		{"Secure Digital", false, "Tarjeta SD", "mmc"},
	}
	for _, c := range casos {
		tipo, bus := tipoYBusDarwin(duInfo{BusProtocol: c.bus, SolidState: c.ssd})
		if tipo != c.tipo || bus != c.busInt {
			t.Errorf("%s (ssd=%v): dio (%q,%q), esperaba (%q,%q)",
				c.bus, c.ssd, tipo, bus, c.tipo, c.busInt)
		}
	}
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
