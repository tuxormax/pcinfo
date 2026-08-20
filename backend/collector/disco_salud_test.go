package collector

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// Disco real del portátil del reporte: Micron de 256 GB, sano, con 11 559 horas
// encendido y 84 % de vida. Es el caso normal, el que más se va a ver.
func discoMicron() DiskInfo {
	return DiskInfo{
		Name: `\\.\PHYSICALDRIVE0`, Model: "Micron MTFDKBA256TFK",
		Type: "SATA SSD", Bus: "SATA", Serial: "00A0_7501_35A0_E2CB.",
		SizeBytes: 256_060_514_304, UsedBytes: 31_400_000_000,
		AvailBytes: 223_900_000_000, SmartAvailable: true, Health: "SALUDABLE",
		HealthLevel: "good", LifePercentUsed: 16, PowerOnHours: 11559,
		PowerCycles: 90917, ReallocatedSectors: 0,
		WrittenBytes: 39_035_000_000_000, ReadBytes: 52_800_000_000_000,
	}
}

func TestVeredictoDiscoSano(t *testing.T) {
	d := discoMicron()
	interpretaDisco(&d)

	if !strings.Contains(d.Verdict, "sano") {
		t.Fatalf("veredicto = %q", d.Verdict)
	}
	titulos := map[string]bool{}
	for _, n := range d.Notes {
		titulos[n.Title] = true
		if n.Detail == "" {
			t.Errorf("la nota %q se quedó sin explicación", n.Title)
		}
	}
	for _, esperado := range []string{
		"Cuánta vida le queda", "Cuánto lleva funcionando",
		"Cuánto se ha escrito en él", "Trozos dañados del disco",
	} {
		if !titulos[esperado] {
			t.Errorf("falta la explicación %q", esperado)
		}
	}
	// Un disco sano NO debe salir con notas de aviso: sería alarmar sin motivo.
	for _, n := range d.Notes {
		if n.Level != NotaInfo {
			t.Errorf("nota %q con nivel %q en un disco sano", n.Title, n.Level)
		}
	}
}

func TestVeredictoDiscoFallando(t *testing.T) {
	d := discoMicron()
	d.HealthLevel = "fail"
	d.ReallocatedSectors = 240
	d.Issues = []DiskIssue{{"fail", "SMART reporta fallo inminente", "El disco declara que falla."}}
	interpretaDisco(&d)

	if !strings.Contains(strings.ToLower(d.Verdict), "copia de seguridad") {
		t.Fatalf("un disco que falla tiene que mandar respaldar; dijo: %q", d.Verdict)
	}
	var hayQueHacer bool
	for _, n := range d.Notes {
		if n.Title == "Qué se puede hacer" {
			hayQueHacer = true
		}
	}
	if !hayQueHacer {
		t.Error("falta la nota de qué hacer")
	}
}

func TestDiscoSinSaludYRemovible(t *testing.T) {
	usb := DiskInfo{Model: "SanDisk Cruzer", Removable: true}
	interpretaDisco(&usb)
	if !strings.Contains(usb.Verdict, "extraíble") || len(usb.Notes) != 0 {
		t.Errorf("una memoria USB no se analiza: %q / %d notas", usb.Verdict, len(usb.Notes))
	}

	mudo := DiskInfo{Model: "Disco en gabinete", SmartAvailable: false}
	interpretaDisco(&mudo)
	if mudo.Verdict == "" {
		t.Error("un disco sin salud tiene que decir POR QUÉ no la hay")
	}
}

func TestTiempoEnPalabras(t *testing.T) {
	for horas, esperado := range map[int]string{
		11559: "1 año y 3 meses",
		8760:  "1 año",
		2200:  "3 meses",
		100:   "4 días",
		5:     "5 horas",
	} {
		if got := tiempoEnPalabras(horas); got != esperado {
			t.Errorf("tiempoEnPalabras(%d) = %q, se esperaba %q", horas, got, esperado)
		}
	}
}

// Igual que en la batería: escribe el JSON del disco para ver la pestaña en el
// escritorio sin tener ese equipo delante.
func TestVistaPreviaDiscos(t *testing.T) {
	destino := os.Getenv("PCINFO_VISTA_PREVIA_DISCOS")
	if destino == "" {
		t.Skip("sin PCINFO_VISTA_PREVIA_DISCOS")
	}
	sano := discoMicron()
	interpretaDisco(&sano)

	viejo := DiskInfo{
		Name: `\\.\PHYSICALDRIVE1`, Model: "WDC WD10EZEX-75WN4A0", Type: "HDD",
		Bus: "SATA", Serial: "WD-WCC6Y0HKZ1TP", SizeBytes: 1_000_204_886_016,
		UsedBytes: 820_000_000_000, AvailBytes: 180_204_886_016,
		SmartAvailable: true, Health: "PELIGRO", HealthLevel: "warning",
		LifePercentUsed: -1, PowerOnHours: 46320, PowerCycles: 3120,
		ReallocatedSectors: 18, WrittenBytes: 0,
		Issues: []DiskIssue{{"warning", "Sectores reasignados",
			"El disco ya reemplazó sectores dañados por otros de reserva. Consecuencia: desgaste en marcha; si el número crece, el disco fallará. (valor: 18)."}},
	}
	interpretaDisco(&viejo)

	datos, err := json.MarshalIndent(map[string]any{"discos": []DiskInfo{sano, viejo}}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destino, datos, 0o644); err != nil {
		t.Fatal(err)
	}
}
