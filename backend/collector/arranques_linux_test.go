//go:build linux

package collector

import (
	"testing"
	"time"
)

// Historial de ejemplo con los cuatro finales posibles, en el formato exacto
// que imprime `last --time-format=iso -x reboot shutdown`.
const salidaLast = `reboot   system boot  6.8.0-138-generi 2026-09-07T06:30:12-06:00   still running
reboot   system boot  6.8.0-138-generi 2026-09-06T06:30:20-06:00 - crash  (13:29)
shutdown system down  6.8.0-138-generi 2026-09-05T20:00:44-06:00 - 2026-09-06T06:30:20-06:00  (10:29)
reboot   system boot  6.8.0-138-generi 2026-09-05T06:30:10-06:00 - 2026-09-05T20:00:44-06:00  (13:30)
shutdown system down  6.8.0-138-generi 2026-09-05T06:29:40-06:00 - 2026-09-05T06:30:10-06:00  (00:00)
reboot   system boot  6.8.0-138-generi 2026-09-04T06:30:00-06:00 - 2026-09-05T06:29:40-06:00  (23:59)

wtmp begins Mon Aug 10 08:00:01 2026
`

// El caso que motivó el módulo: un equipo que debía apagarse solo a las 20:00 y
// un domingo no lo hizo. Lo que hay que ver de un vistazo es que esa sesión NO
// terminó en un apagado ordenado.
func TestParseaSalidaLastDistingueLosFinales(t *testing.T) {
	ahora := time.Date(2026, 9, 7, 12, 30, 0, 0, time.Local)
	ses := parseaSalidaLast(salidaLast, ahora)

	if len(ses) != 4 {
		t.Fatalf("se esperaban 4 sesiones, salieron %d: %+v", len(ses), ses)
	}
	casos := []struct {
		i      int
		quiero string
	}{
		{0, FinEnCurso},  // "still running"
		{1, FinBrusco},   // "- crash": nunca vio su apagado
		{2, FinNormal},   // apagado ordenado con su línea de shutdown
		{3, FinReinicio}, // se apagó y volvió a encender 30 s después
	}
	for _, c := range casos {
		if ses[c.i].Ended != c.quiero {
			t.Errorf("sesión %d (%s): se esperaba %q y salió %q",
				c.i, ses[c.i].Start, c.quiero, ses[c.i].Ended)
		}
	}
}

func TestParseaSalidaLastCalculaDuracionYNucleo(t *testing.T) {
	ahora := time.Date(2026, 9, 7, 12, 30, 0, 0, time.Local)
	ses := parseaSalidaLast(salidaLast, ahora)

	// La sesión en curso se mide contra "ahora", no contra el registro.
	// 06:30:12 → 12:30:00 son 5 h 59 min 48 s.
	if ses[0].SecondsUp != 21588 {
		t.Errorf("la sesión en curso debía llevar 21588 s, lleva %d s", ses[0].SecondsUp)
	}
	if ses[0].End != "" {
		t.Errorf("la sesión en curso no debe tener hora de apagado, tiene %q", ses[0].End)
	}
	// El registro de accesos recorta el núcleo a 16 caracteres: se toma tal cual,
	// pero tiene que ser el núcleo y no la palabra "boot" de la propia línea.
	if ses[0].Kernel != "6.8.0-138-generi" {
		t.Errorf("núcleo mal leído: %q", ses[0].Kernel)
	}
	// Sesión completa: 2026-09-05 06:30:10 → 20:00:44 = 13 h 30 min.
	if got := duracionLlana(ses[2].SecondsUp); got != "13 h 30 min" {
		t.Errorf("duración esperada \"13 h 30 min\", salió %q", got)
	}
}

// Una sesión cuyo apagado quedó fuera de la ventana de análisis no se muestra:
// el reporte dice "últimos 30 días" y tiene que ser verdad.
func TestParseaSalidaLastDescartaLoViejo(t *testing.T) {
	ahora := time.Date(2026, 12, 1, 0, 0, 0, 0, time.Local)
	ses := parseaSalidaLast(salidaLast, ahora)
	for _, s := range ses {
		if s.Ended != FinEnCurso {
			t.Errorf("no debía quedar ninguna sesión terminada: %+v", s)
		}
	}
}

func TestParseaBootsTexto(t *testing.T) {
	// Formato de systemd 254+, con cabecera: la línea de títulos no debe colarse
	// como si fuera un arranque.
	salida := `IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -1 4a1c00000000000000000000000000aa Sat 2026-09-06 06:30:20 CST Sat 2026-09-06 20:00:44 CST
  0 a8e700000000000000000000000000bb Sun 2026-09-07 06:30:12 CST Sun 2026-09-07 12:55:01 CST`

	r := parseaBootsTexto(salida)
	if len(r) != 2 {
		t.Fatalf("se esperaban 2 arranques, salieron %d", len(r))
	}
	if r[0].idx != -1 || r[1].idx != 0 {
		t.Errorf("los índices salieron desordenados: %d, %d", r[0].idx, r[1].idx)
	}
	if r[0].ini.Format("2006-01-02 15:04:05") != "2026-09-06 06:30:20" {
		t.Errorf("fecha de inicio mal leída: %v", r[0].ini)
	}
}

func TestParseaBootsJSON(t *testing.T) {
	// first_entry/last_entry en microsegundos; distintas versiones de systemd los
	// serializan como número o como texto y las dos formas deben valer.
	salida := `[{"index":-1,"boot_id":"aa","first_entry":1788697820000000,"last_entry":"1788746444000000"}]`
	r := parseaBootsJSON(salida)
	if len(r) != 1 {
		t.Fatalf("se esperaba 1 arranque, salieron %d", len(r))
	}
	if r[0].ini.Unix() != 1788697820 {
		t.Errorf("first_entry mal convertido: %v", r[0].ini)
	}
	if r[0].fin.Unix() != 1788746444 {
		t.Errorf("last_entry como texto mal convertido: %v", r[0].fin)
	}
}
