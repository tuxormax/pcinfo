package collector

import (
	"encoding/json"
	"strings"
	"testing"
)

// Candado del catálogo de casos conocidos: valida el archivo entero en cada
// `go test`. Es un texto que se le enseña al usuario como verdad ("esto está
// así a propósito"), así que una fila a medias es peor que no tenerla.
func TestCatalogoCasosConocidos(t *testing.T) {
	var crudo []CasoConocido
	if err := json.Unmarshal(casosEmbebidos, &crudo); err != nil {
		t.Fatalf("controladores_conocidos.json no es JSON válido: %v", err)
	}
	if len(crudo) == 0 {
		t.Fatal("el catálogo está vacío")
	}
	if n := len(compilaCasos(casosEmbebidos)); n != len(crudo) {
		t.Fatalf("filas descartadas al compilar: %d de %d sobrevivieron", n, len(crudo))
	}

	vias := map[string]bool{ViaQuitar: true, ViaGenerico: true, ViaFabricante: true}
	vistos := map[string]bool{}
	for _, c := range crudo {
		if vistos[c.ID] {
			t.Errorf("%s: id repetido", c.ID)
		}
		vistos[c.ID] = true
		if !vias[c.Via] {
			t.Errorf("%s: vía desconocida %q", c.ID, c.Via)
		}
		for campo, valor := range map[string]string{
			"nombre": c.Nombre, "descripcion": c.Descripcion,
			"motivo": c.Motivo, "fuente": c.Fuente,
		} {
			if strings.TrimSpace(valor) == "" {
				t.Errorf("%s: %s vacío", c.ID, campo)
			}
		}
		// Sin fuente verificable el texto no se publica: es la misma regla del
		// catálogo de placas.
		if !strings.Contains(c.Fuente, "arreglador") {
			t.Errorf("%s: la fuente no dice de dónde salió el dato (%q)", c.ID, c.Fuente)
		}
		// Un patrón de solo fabricante (VEN_xxxx sin DEV_) etiqueta cualquier
		// aparato de esa marca. Solo se admite cuando la marca hace una sola
		// cosa en un PC; el resto quedó fuera del catálogo a propósito.
		if strings.Count(c.BuscarID, "VEN_") > 0 && !strings.Contains(c.BuscarID, "DEV_") {
			if !soloUnaCosa[c.ID] {
				t.Errorf("%s: patrón por fabricante sin DEV_, no está en la lista revisada", c.ID)
			}
		}
	}
}

// Fabricantes que en un PC hacen una sola cosa, revisados a mano: se les admite
// el patrón VEN_ a secas.
var soloUnaCosa = map[string]bool{
	"conexant":     true, // VEN_14F1 — audio en portátiles
	"idt-audio":    true, // VEN_111D — audio
	"atheros-wifi": true, // VEN_168C — tarjetas inalámbricas
	"huella":       true, // VEN_138A / VEN_147E — lectores de huella
}

func TestExplicaDispositivoReconoceCasos(t *testing.T) {
	casos := []struct{ id, hardware string }{
		{"dptf", `ACPI\INT3400\2&DABA3FF&1`},
		{"conexant", `HDAUDIO\FUNC_01&VEN_14F1&DEV_5111`},
		{"realtek-cardreader", `PCI\VEN_10EC&DEV_5227&SUBSYS_80FA1028`},
		{"serialio", `ACPI\INT33C3\0`},
	}
	for _, c := range casos {
		got := explicaDispositivo(c.hardware)
		if got == nil {
			t.Errorf("%s: no se reconoció %s", c.id, c.hardware)
			continue
		}
		if got.ID != c.id {
			t.Errorf("%s: se reconoció como %s", c.id, got.ID)
		}
	}
}

// INT3400 cae dentro del rango INT34xx del Serial IO además de ser el DPTF. El
// desempate es el orden del archivo, y tiene que ganar el DPTF: es el que trae
// el motivo real de que ese dispositivo esté sin controlador.
func TestPatronesQueSeSolapanGanaElPrimero(t *testing.T) {
	c := explicaDispositivo(`ACPI\INT3400\0`)
	if c == nil || c.ID != "dptf" {
		t.Fatalf("INT3400 debería ser dptf, salió %+v", c)
	}
}

func TestDispositivoNormalNoSeExplica(t *testing.T) {
	if c := explicaDispositivo(`PCI\VEN_8086&DEV_A36D&SUBSYS_86941043`); c != nil {
		t.Fatalf("un dispositivo cualquiera no debería coincidir: %s", c.ID)
	}
	if c := explicaDispositivo("", " "); c != nil {
		t.Fatalf("sin ids no debería coincidir nada: %s", c.ID)
	}
}

func TestExplicaPendientesOrdenaYRedacta(t *testing.T) {
	out := explicaPendientes([]DispositivoPendiente{
		{Nombre: "Zeta sin nada", Codigo: 28, InstanceID: `PCI\VEN_1AF4&DEV_1000`},
		{Nombre: "", Codigo: 99, InstanceID: `SW\RARO`},
		{Nombre: "Audio", Codigo: 28, InstanceID: `HDAUDIO\FUNC_01&VEN_14F1&DEV_5111`,
			HardwareID: `HDAUDIO\FUNC_01&VEN_14F1&DEV_5111&SUBSYS_102805CA HDAUDIO\FUNC_01&VEN_14F1`},
	})
	if len(out) != 3 {
		t.Fatalf("se perdieron filas: %d", len(out))
	}
	if out[0].Conocido == nil || out[0].Conocido.ID != "conexant" {
		t.Fatalf("el reconocido tiene que ir primero, salió %+v", out[0])
	}
	if strings.Contains(out[0].HardwareID, " ") {
		t.Errorf("solo se enseña el primer id de hardware: %q", out[0].HardwareID)
	}
	if out[0].Estado != textoCodigoPnP(28) {
		t.Errorf("estado sin redactar: %q", out[0].Estado)
	}
	for _, d := range out {
		if d.Nombre == "" {
			t.Error("un dispositivo sin nombre quedaría como una fila en blanco")
		}
		if d.Estado == "" {
			t.Error("todo dispositivo con problema tiene que decir qué le pasa")
		}
	}
}
