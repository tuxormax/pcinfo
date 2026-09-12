package collector

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Pruebas del análisis del registro del sistema contra una muestra REAL de la
// Mac mini (testdata/darwin/log_incidencias_disco.txt). Sin etiqueta de
// plataforma: corren también en Linux.

func lineasMuestra(t *testing.T, nombre string) []string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "darwin", nombre))
	if err != nil {
		t.Fatalf("no pude leer %s: %v", nombre, err)
	}
	return strings.Split(string(b), "\n")
}

// discoDePrueba imita el disco USB de 2 TB: el registro lo nombra "[Tech]" y el
// modelo que da diskutil es "JMicron Tech".
func discoDePrueba() []DiskInfo {
	return []DiskInfo{{
		Name:      "/dev/disk4",
		Model:     "JMicron Tech",
		SizeBytes: 2000398934016,
	}}
}

func TestIncidenciasDiscoUSB(t *testing.T) {
	inc := AnalizaIncidencias(lineasMuestra(t, "log_incidencias_disco.txt"), discoDePrueba())
	if len(inc) == 0 {
		t.Fatal("la muestra tiene errores de disco y no salió ninguna incidencia")
	}
	var d *IncidenciaDisco
	for i := range inc {
		if inc[i].Device == "/dev/disk4" {
			d = &inc[i]
		}
	}
	if d == nil {
		t.Fatalf("no se atribuyó nada a /dev/disk4; salió %+v", inc)
	}

	// ⭐ El detalle (posiciones que fallaron) llega con la ETIQUETA del sistema
	// y el resumen con el DISPOSITIVO: si no se unen, el disco sale partido en
	// dos fichas.
	if d.Etiqueta != "Tech" {
		t.Errorf("etiqueta: %q — hace falta para unir el resumen con el detalle", d.Etiqueta)
	}
	if d.ErroresES == 0 {
		t.Error("no contó los errores de E/S del resumen")
	}
	if d.SectoresMalos == 0 {
		t.Error("no contó las posiciones distintas que fallaron (el detalle)")
	}
	// La clave de sense 0x04 es HARDWARE ERROR: el disco contestó que falló por
	// dentro. ⚠️ El registro la escribe "0x04", no "0x4".
	if !d.FalloInterno {
		t.Error("la muestra trae Sense Data 0x04 (fallo interno) y no se detectó")
	}
	// Sense 0x02/0x04 = el disco estaba arrancando el motor.
	if d.Arranques == 0 {
		t.Error("la muestra trae Sense Data 0x02, 0x04 (arrancando) y no se contó")
	}
	if !d.Conectado {
		t.Error("el disco de la prueba está en la lista de discos: debe salir como conectado")
	}
	if d.Veredicto == "" {
		t.Error("todo disco con incidencias lleva veredicto redactado")
	}
}

func TestExpulsionOrdenadaNoEsCaida(t *testing.T) {
	// ⛔ Una expulsión ORDENADA se anuncia antes ("ejected … ongoing"); una
	// desconexión de sorpresa llega a pelo. Si no se distinguen, cada imagen de
	// disco (.dmg) que se monta y desmonta se cuenta como "un disco se
	// desconectó solo", que es alarmar por nada.
	ordenada := []string{
		"2026-09-12 12:00:00.000 Df diskarbitrationd[122:1] [x] ejected disk, id = /dev/disk9, ongoing.",
		"2026-09-12 12:00:00.100 Df diskarbitrationd[122:1] [x] removed disk, id = /dev/disk9.",
		"2026-09-12 12:00:00.200 Df diskarbitrationd[122:1] [x] ejected disk, id = /dev/disk9, success.",
	}
	discos := []DiskInfo{{Name: "/dev/disk9", Model: "Imagen", SizeBytes: 1 << 30}}
	for _, in := range AnalizaIncidencias(ordenada, discos) {
		if in.Desconexiones != 0 {
			t.Errorf("una expulsión en orden no es una caída: %+v", in)
		}
	}

	sorpresa := []string{
		"2026-09-12 12:00:00.000 Df diskarbitrationd[122:1] [x] removed disk, id = /dev/disk9.",
		"2026-09-12 12:00:15.000 Df diskarbitrationd[122:1] [x] unmounted disk, id = /dev/disk9s2, success.",
	}
	hallado := false
	for _, in := range AnalizaIncidencias(sorpresa, discos) {
		if in.Device == "/dev/disk9" && in.Desconexiones == 1 {
			hallado = true
		}
	}
	if !hallado {
		t.Error("un «removed» sin aviso previo SÍ es una desconexión de sorpresa")
	}
}

func TestZonasSeAgrupanYSeOrdenan(t *testing.T) {
	// Que los fallos estén AGRUPADOS o dispersos es lo que distingue un disco con
	// una zona dañada de uno que se quedó sin responder: por eso se agrupan.
	lbas := map[uint64]uint64{}
	for i := uint64(0); i < 50; i++ { // zona grande cerca del GB 100
		lbas[100*1000*1000*1000/512+i*8] = 8
	}
	lbas[500*1000*1000*1000/512] = 8 // un fallo suelto cerca del GB 500

	z := agrupaZonas(lbas)
	if len(z) != 2 {
		t.Fatalf("esperaba 2 zonas (una agrupada y una suelta), salieron %d: %+v", len(z), z)
	}
	if z[0].Sectores <= z[1].Sectores {
		t.Error("la zona con más fallos va primero: es la que importa")
	}
	if z[0].DesdeGB < 99 || z[0].DesdeGB > 101 {
		t.Errorf("la zona grande debía caer cerca del GB 100, dio %.1f", z[0].DesdeGB)
	}
	if z[0].MBIlegibles <= 0 {
		t.Error("hay que estimar cuánto no se pudo leer, no solo cuántas posiciones")
	}
}

func TestSinIncidenciasNoInventaNada(t *testing.T) {
	inc := AnalizaIncidencias([]string{"2026-09-12 10:00:00.000 Df otro[1:1] nada que ver"}, discoDePrueba())
	if len(inc) != 0 {
		t.Errorf("sin incidencias no se devuelve ninguna ficha: %+v", inc)
	}
}
