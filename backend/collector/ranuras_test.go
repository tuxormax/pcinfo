package collector

import "testing"

func TestClasificaRanura(t *testing.T) {
	casos := []struct{ in, kind, spec string }{
		{"x16 PCI Express 3", "pcie", "PCIe 3.0 x16"},
		{"x1 PCI Express 2", "pcie", "PCIe 2.0 x1"},
		{"PCI Express Gen 4 x4", "pcie", "PCIe 4.0 x4"},
		{"PCI Express", "pcie", "PCIe"},
		{"M.2 Socket 3", "m2", "M.2 llave M (PCIe x4 / NVMe)"},
		{"M.2 Socket 2", "m2", "M.2 llave B (SATA / PCIe x2)"},
		// La de WiFi NO puede contarse como sitio para un SSD.
		{"M.2 Socket 1-DP", "m2wifi", "M.2 llave A/E (módulo WiFi)"},
		{"M.2 Socket 1-SD", "m2wifi", "M.2 llave A/E (módulo WiFi)"},
		{"PCI", "pci", "PCI"},
	}
	for _, c := range casos {
		k, s := clasificaRanura(c.in)
		if k != c.kind || s != c.spec {
			t.Errorf("%q → (%q,%q); esperado (%q,%q)", c.in, k, s, c.kind, c.spec)
		}
	}
}

// "Unknown" y "Unavailable" NO son "libre": prometer una ranura libre que no se
// leyó manda al técnico con una tarjeta que quizá no pueda poner.
func TestEstadoRanuraDesconocidoNoEsLibre(t *testing.T) {
	if got := estadoRanura("Available"); got != "libre" {
		t.Errorf("Available → %q", got)
	}
	if got := estadoRanura("In Use"); got != "ocupada" {
		t.Errorf("In Use → %q", got)
	}
	for _, s := range []string{"Unknown", "Unavailable", "", "Other"} {
		if got := estadoRanura(s); got != "" {
			t.Errorf("%q → %q; debía quedar sin estado", s, got)
		}
	}
}

func TestFusionaConCatalogoCasaPorEtiqueta(t *testing.T) {
	cat := []ExpansionSlot{
		{Label: "PCIEX16_1", Kind: "pcie", Spec: "PCIe 3.0 x16", Source: "catalogo"},
		{Label: "M.2_1", Kind: "m2", Spec: "PCIe 3.0 x4 / SATA", Source: "catalogo"},
	}
	fw := []ExpansionSlot{
		{Label: "M2_1", Kind: "m2", State: "ocupada"},
		{Label: "PCIEX16 1", Kind: "pcie", State: "libre"},
	}
	got := fusionaConCatalogo(cat, fw)
	if got[0].State != "libre" || got[1].State != "ocupada" {
		t.Fatalf("estados mal casados: %+v", got)
	}
	if got[0].Spec != "PCIe 3.0 x16" || got[0].Source != "catalogo" {
		t.Errorf("el catálogo debe mandar sobre el firmware en la ficha: %+v", got[0])
	}
}

// Cuando el firmware nombra las ranuras a su manera, se casan por orden dentro
// del mismo tipo; lo que no case se queda SIN estado.
func TestFusionaConCatalogoPorOrdenYSinInventar(t *testing.T) {
	cat := []ExpansionSlot{
		{Label: "PCIEX16_1", Kind: "pcie"},
		{Label: "PCIEX1_1", Kind: "pcie"},
		{Label: "M.2_1", Kind: "m2"},
	}
	fw := []ExpansionSlot{
		{Label: "PCIe Slot 1", Kind: "pcie", State: "ocupada"},
		{Label: "PCIe Slot 2", Kind: "pcie", State: "libre"},
	}
	got := fusionaConCatalogo(cat, fw)
	if got[0].State != "ocupada" || got[1].State != "libre" {
		t.Fatalf("no casó por orden: %+v", got)
	}
	if got[2].State != "" {
		t.Errorf("la M.2 sin dato del firmware debía quedar sin estado, quedó %q", got[2].State)
	}
}

// Un SSD NVMe conectado ocupa una M.2 aunque el firmware diga que está libre;
// y la gráfica INTEGRADA no ocupa ninguna ranura.
func TestMarcaOcupacionReal(t *testing.T) {
	slots := []ExpansionSlot{
		{Label: "PCIEX16_1", Kind: "pcie", Spec: "PCIe 3.0 x16", State: "libre"},
		{Label: "M.2_1", Kind: "m2", Spec: "M.2 llave M", State: "libre"},
		{Label: "M.2_WIFI", Kind: "m2wifi", Spec: "M.2 llave A/E", State: "libre"},
	}
	disks := []DiskInfo{{Name: "/dev/nvme0n1", Model: "SN570", Bus: "nvme"}}
	gpu := GPUInfo{Cards: []GPUCard{{Vendor: "AMD", Product: "Picasso [Radeon Vega Series]"}}}
	marcaOcupacionReal(slots, disks, gpu)

	if slots[1].State != "ocupada" || slots[1].UsedBy == "" {
		t.Errorf("la M.2 con NVMe puesto debe salir ocupada: %+v", slots[1])
	}
	if slots[2].State != "libre" {
		t.Errorf("la M.2 de WiFi no la ocupa un SSD: %+v", slots[2])
	}
	if slots[0].State != "libre" {
		t.Errorf("la gráfica integrada no ocupa la PCIe x16: %+v", slots[0])
	}
}

func TestMarcaOcupacionRealGraficaDedicada(t *testing.T) {
	slots := []ExpansionSlot{{Label: "PCIEX16_1", Kind: "pcie", Spec: "PCIe 3.0 x16", State: "libre"}}
	gpu := GPUInfo{Cards: []GPUCard{{Vendor: "NVIDIA", Product: "GeForce GTX 1650"}}}
	marcaOcupacionReal(slots, nil, gpu)
	if slots[0].State != "ocupada" || slots[0].UsedBy != "NVIDIA GeForce GTX 1650" {
		t.Errorf("la tarjeta dedicada ocupa la x16: %+v", slots[0])
	}
}

func TestOrdenaRanuras(t *testing.T) {
	s := []ExpansionSlot{
		{Kind: "m2wifi", Spec: "M.2 llave A/E"},
		{Kind: "pcie", Spec: "PCIe 3.0 x1"},
		{Kind: "m2", Spec: "M.2 llave M"},
		{Kind: "pcie", Spec: "PCIe 3.0 x16"},
	}
	ordenaRanuras(s)
	quiere := []string{"PCIe 3.0 x16", "PCIe 3.0 x1", "M.2 llave M", "M.2 llave A/E"}
	for i, q := range quiere {
		if s[i].Spec != q {
			t.Errorf("posición %d = %q; esperado %q", i, s[i].Spec, q)
		}
	}
}

func TestPuertoPorBus(t *testing.T) {
	if puertoPorBus("nvme") != "M.2 / PCIe" || puertoPorBus("sata") != "SATA" {
		t.Error("etiqueta de respaldo incorrecta")
	}
	if puertoPorBus("virtio") != "" {
		t.Error("un bus desconocido no debe inventar puerto")
	}
}

// Integración con el catálogo real: la placa del reporte que destapó todo esto
// (ambio-server, ASUS PRIME B450M-A) tiene que salir con sus 6 conectores SATA
// del catálogo, no con los 12 puertos que presenta el chipset.
func TestEnrichBoardPortsUsaCatalogo(t *testing.T) {
	board := BoardInfo{Vendor: "ASUSTeK COMPUTER INC.", Product: "PRIME B450M-A"}
	disks := []DiskInfo{
		{Name: "/dev/sda", Model: "KINGSTON SA400S37240G", Bus: "sata", Port: "SATA 4"},
		{Name: "/dev/sdb", Model: "WDC WD2000F9YZ", Bus: "sata", Port: "SATA 5"},
	}
	enrichBoardPorts(&board, disks, GPUInfo{})

	if board.SataDeclared != 6 {
		t.Errorf("conectores SATA del catálogo = %d; esperado 6", board.SataDeclared)
	}
	if board.SataUsed != 2 {
		t.Errorf("SATA ocupados = %d; esperado 2", board.SataUsed)
	}
	if board.PortsSource != "catalogo" {
		t.Errorf("fuente = %q; esperado catalogo", board.PortsSource)
	}
	if len(board.Slots) == 0 {
		t.Error("la placa está catalogada con M.2: debería traer ranuras")
	}
}

// Una placa que no está en el catálogo no debe inventarse conectores: se queda
// con lo que diga el firmware/sistema y la GUI lo avisa.
func TestEnrichBoardPortsPlacaDesconocida(t *testing.T) {
	board := BoardInfo{Vendor: "Marca Que No Existe", Product: "XYZ-999"}
	enrichBoardPorts(&board, nil, GPUInfo{})
	if board.SataDeclared != 0 {
		t.Errorf("no catalogada: SataDeclared debe quedar en 0, quedó %d", board.SataDeclared)
	}
	if board.PortsSource == "catalogo" {
		t.Error("no catalogada: la fuente no puede ser el catálogo")
	}
}
