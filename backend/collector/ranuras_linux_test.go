//go:build linux

package collector

import "testing"

func TestPuertoDesdeRuta(t *testing.T) {
	casos := []struct{ ruta, nombre, quiere string }{
		// SATA: el número sale del ataN de la ruta real en sysfs.
		{"/sys/devices/pci0000:00/0000:00:17.0/ata3/host2/target2:0:0/2:0:0:0/block/sdb", "sdb", "SATA 3"},
		{"/sys/devices/pci0000:00/0000:00:01.2/0000:02:00.0/ata12/host11/target11:0:0/11:0:0:0/block/sdc", "sdc", "SATA 12"},
		// NVMe.
		{"/sys/devices/pci0000:00/0000:00:01.1/0000:01:00.0/nvme/nvme0/nvme0n1", "nvme0n1", "M.2 / PCIe (nvme0n1)"},
		// Un disco USB también cuelga de un host SCSI: USB manda.
		{"/sys/devices/pci0000:00/0000:00:14.0/usb2/2-1/2-1:1.0/host6/target6:0:0/6:0:0:0/block/sdd", "sdd", "USB"},
		{"/sys/devices/pci0000:00/0000:00:14.0/mmc_host/mmc0/mmc0:0001/block/mmcblk0", "mmcblk0", "Lector de tarjetas"},
		// Sin pistas: no se inventa nada (lo rellena puertoPorBus).
		{"/sys/devices/virtual/block/vda", "vda", ""},
	}
	for _, c := range casos {
		if got := puertoDesdeRuta(c.ruta, c.nombre); got != c.quiere {
			t.Errorf("%s → %q; esperado %q", c.nombre, got, c.quiere)
		}
	}
}

func TestClasePCI(t *testing.T) {
	if clasePCI("0x030000") != "tarjeta gráfica" {
		t.Error("clase VGA")
	}
	if clasePCI("0x010802") != "SSD NVMe" {
		t.Error("clase NVMe")
	}
	if clasePCI("0x123456") != "tarjeta de expansión" {
		t.Error("clase desconocida debe caer al genérico")
	}
}

// Un bloque de `dmidecode -t 9` tal cual lo imprime la herramienta (placa ASUS
// PRIME B450M-A). Se prueba sin dmidecode ni root, que es justo lo que impide
// probar esto en el equipo de desarrollo.
func TestRanuraDesdeBloque(t *testing.T) {
	casos := []struct {
		b     map[string]string
		label string
		kind  string
		spec  string
		state string
	}{
		{map[string]string{"Designation": "PCIEX16_1", "Type": "x16 PCI Express 3",
			"Current Usage": "In Use", "Length": "Long"}, "PCIEX16_1", "pcie", "PCIe 3.0 x16", "ocupada"},
		{map[string]string{"Designation": "M.2_1", "Type": "M.2 Socket 3",
			"Current Usage": "Available"}, "M.2_1", "m2", "M.2 llave M (PCIe x4 / NVMe)", "libre"},
		// Sin designación: se usa la especificación como nombre visible.
		{map[string]string{"Type": "x1 PCI Express 2", "Current Usage": "Unknown"},
			"PCIe 2.0 x1", "pcie", "PCIe 2.0 x1", ""},
	}
	for _, c := range casos {
		s, ok := ranuraDesdeBloque(c.b)
		if !ok {
			t.Fatalf("bloque descartado: %v", c.b)
		}
		if s.Label != c.label || s.Kind != c.kind || s.Spec != c.spec || s.State != c.state {
			t.Errorf("%v → %+v", c.b, s)
		}
		if s.Source != "firmware" {
			t.Errorf("la fuente debe ser el firmware, es %q", s.Source)
		}
	}
	// La cabecera que imprime dmidecode antes del primer handle no es una ranura.
	if _, ok := ranuraDesdeBloque(map[string]string{"SMBIOS": "3.2 present"}); ok {
		t.Error("un bloque sin tipo ni uso no puede pasar por ranura")
	}
}
