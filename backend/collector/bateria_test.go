package collector

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// Caso real: portátil Lenovo 80VF del que se tiene el informe de batería de
// Windows (battery-report.html). Sirve de doble control: que la salud se calcule
// como la calcula Windows (67 900 / 78 000 = 87 %) y que el veredicto sea el que
// le corresponde.
func TestSaludBateriaLenovo(t *testing.T) {
	b := BatteryItem{
		Name:          "BASE-BAT",
		Manufacturer:  "Simplo",
		Serial:        "123456789",
		Chemistry:     "LiP",
		DesignMWh:     78000,
		FullMWh:       67900,
		RemainingMWh:  66250,
		ChargePercent: 98,
		CycleCount:    0,
		State:         EstadoConectada,
	}
	interpretaBateria(&b)

	if b.HealthPercent != 87 {
		t.Fatalf("salud = %d, se esperaba 87", b.HealthPercent)
	}
	if b.HealthLevel != SaludBien {
		t.Fatalf("nivel = %q, se esperaba %q", b.HealthLevel, SaludBien)
	}
	if b.ChemistryText != "Polímero de litio" {
		t.Fatalf("química = %q", b.ChemistryText)
	}
	// Sin ciclos contados NO se puede quedar callado: hay que decir que el
	// equipo no lleva la cuenta, o el usuario creerá que es un fallo.
	if len(b.Notes) < 3 {
		t.Fatalf("se esperaban al menos 3 explicaciones, hay %d", len(b.Notes))
	}
	if !strings.Contains(b.Notes[0].Detail, "78 Wh") {
		t.Fatalf("la explicación no dice la capacidad de fábrica: %q", b.Notes[0].Detail)
	}
}

func TestNivelesDeSalud(t *testing.T) {
	casos := []struct {
		full, design int
		salud        int
		nivel        string
	}{
		{78000, 78000, 100, SaludBien},
		{67900, 78000, 87, SaludBien},
		{62400, 78000, 80, SaludBien},
		{54600, 78000, 70, SaludAviso},
		{35100, 78000, 45, SaludAviso},
		{23400, 78000, 30, SaludMal},
		{0, 78000, -1, ""},
		{67900, 0, -1, ""},
		// Batería nueva que reporta más de lo que dice la etiqueta: se recorta a
		// 100 % en vez de enseñar un 103 % que nadie entiende.
		{80000, 78000, 100, SaludBien},
	}
	for _, c := range casos {
		b := BatteryItem{FullMWh: c.full, DesignMWh: c.design, CycleCount: -1, ChargePercent: -1}
		interpretaBateria(&b)
		if b.HealthPercent != c.salud || b.HealthLevel != c.nivel {
			t.Errorf("%d/%d → salud %d nivel %q; se esperaba %d / %q",
				c.full, c.design, b.HealthPercent, b.HealthLevel, c.salud, c.nivel)
		}
		if b.Verdict == "" {
			t.Errorf("%d/%d se quedó sin veredicto", c.full, c.design)
		}
	}
}

func TestMiles(t *testing.T) {
	for entrada, esperado := range map[int]string{
		0: "0", 999: "999", 1000: "1.000", 78000: "78.000", 1234567: "1.234.567",
	} {
		if got := miles(entrada); got != esperado {
			t.Errorf("miles(%d) = %q, se esperaba %q", entrada, got, esperado)
		}
	}
}

// TestVistaPreviaLenovo no es una prueba de regresión: escribe en
// PCINFO_VISTA_PREVIA el JSON que el backend daría para ese portátil, para
// poder ver en el escritorio cómo quedaría la pestaña sin tener el equipo
// delante. Sin la variable de entorno no hace nada.
func TestVistaPreviaLenovo(t *testing.T) {
	destino := os.Getenv("PCINFO_VISTA_PREVIA")
	if destino == "" {
		t.Skip("sin PCINFO_VISTA_PREVIA")
	}
	rep := BatteryReport{
		OS:        "windows",
		Supported: true,
		Available: true,
		Source:    "Informe de batería de Windows (powercfg) y WMI",
		Generated: "2026-08-20 09:24",
		OnAC:      true,
		OnACKnown: true,
		Equipment: "Lenovo YOGA 910-13IKB (80VF)",
		Batteries: []BatteryItem{{
			Name: "BASE-BAT", Manufacturer: "Simplo", Serial: "123456789",
			Chemistry: "LiP", VoltageMV: 7680, DesignMWh: 78000, FullMWh: 67900,
			RemainingMWh: 66250, ChargePercent: 98, CycleCount: 0,
			State: EstadoConectada,
		}},
		RuntimeFullMin:   392,
	}
	for _, h := range [][3]any{
		{"27/06/2026 – 04/07/2026", 66040, 78000},
		{"04/07/2026 – 11/07/2026", 65382, 78000},
		{"11/07/2026 – 18/07/2026", 65380, 78000},
		{"18/07/2026 – 25/07/2026", 65380, 78000},
		{"25/07/2026 – 01/08/2026", 66105, 78000},
		{"01/08/2026 – 08/08/2026", 64012, 78000},
		{"09/08/2026", 62010, 78000},
		{"12/08/2026", 62010, 78000},
		{"15/08/2026", 62010, 78000},
		{"18/08/2026", 62010, 78000},
		{"19/08/2026", 63862, 78000},
	} {
		rep.History = append(rep.History, BatteryPoint{
			Period: h[0].(string), FullMWh: h[1].(int), DesignMWh: h[2].(int),
		})
	}
	rep.HasBattery = true
	for i := range rep.Batteries {
		interpretaBateria(&rep.Batteries[i])
	}
	calculaConsumo(&rep)
	for i := range rep.History {
		rep.History[i].HealthPercent = porcentajeSalud(rep.History[i].FullMWh, rep.History[i].DesignMWh)
	}
	datos, err := json.MarshalIndent(rep, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destino, datos, 0o644); err != nil {
		t.Fatal(err)
	}
}
