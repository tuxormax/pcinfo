package collector

import (
	"encoding/json"
	"strings"
	"testing"
)

// El catálogo es un archivo escrito a mano/semiautomático: este test es el
// candado que impide que una fila mal formada llegue a producción. Un dato
// inventado o incoherente en el catálogo MANDA sobre el firmware, así que un
// error aquí se ve en pantalla como si fuera verdad.
func TestCatalogoPuertosCoherente(t *testing.T) {
	var placas []PlacaSpec
	if err := json.Unmarshal(placasEmbebidas, &placas); err != nil {
		t.Fatalf("placas.json no es JSON válido: %v", err)
	}
	if len(placas) == 0 {
		t.Fatal("catálogo vacío")
	}
	vistas := map[string]bool{}
	for _, p := range placas {
		id := p.Fabricante + " " + p.Modelo
		k := clavePlaca(p.Fabricante, p.Modelo)
		if k == "" {
			t.Errorf("%s: fabricante o modelo vacío", id)
			continue
		}
		if vistas[k] {
			t.Errorf("%s: fila duplicada (misma clave que otra)", id)
		}
		vistas[k] = true

		if p.Sata < 0 || p.Sata > 16 {
			t.Errorf("%s: %d conectores SATA es imposible", id, p.Sata)
		}
		if len(p.M2) > 8 {
			t.Errorf("%s: %d ranuras M.2 es imposible", id, len(p.M2))
		}
		for _, r := range append(append([]RanuraSpec{}, p.M2...), p.PCIe...) {
			if strings.TrimSpace(r.Label) == "" {
				t.Errorf("%s: ranura sin etiqueta", id)
			}
			if strings.TrimSpace(r.Spec) == "" {
				t.Errorf("%s: ranura %q sin especificación", id, r.Label)
			}
		}
		// Una ranura de WiFi NO puede llevar un SSD: si alguna vez se marca
		// wifi=true en una que dice "llave M", el conteo de sitios libres
		// mandaría a comprar un disco que no entra.
		for _, r := range p.M2 {
			if r.WiFi && strings.Contains(strings.ToUpper(r.Spec), "LLAVE M") {
				t.Errorf("%s: la ranura %q está marcada como WiFi pero es llave M", id, r.Label)
			}
		}
		// Si trae datos de expansión, debe traer también de dónde salieron.
		if (p.Sata > 0 || len(p.M2) > 0 || len(p.PCIe) > 0) &&
			strings.TrimSpace(p.Fuente)+strings.TrimSpace(p.FuentePuertos) == "" {
			t.Errorf("%s: trae puertos sin fuente que los respalde", id)
		}
	}
}
