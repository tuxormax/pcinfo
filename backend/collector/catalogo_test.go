package collector

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestBuscaPlaca: el DMI escribe el fabricante y el modelo de formas distintas
// según la placa; todas deben caer en la misma ficha del catálogo.
func TestBuscaPlaca(t *testing.T) {
	casos := []struct {
		fabricante, modelo string
		quiero             bool
	}{
		{"Gigabyte Technology Co., Ltd.", "A520M K V2", true},       // como lo reporta WMI/DMI
		{"GIGABYTE", "A520M K V2 (rev. 1.1)", true},                 // con revisión de placa
		{"gigabyte technology co., ltd.", "a520m k v2", true},       // minúsculas
		{"Gigabyte Technology Co., Ltd.", "Z999M INVENTADA", false}, // placa fuera del catálogo
		{"", "", false}, // DMI vacío
	}
	for _, c := range casos {
		p, ok := buscaPlaca(c.fabricante, c.modelo)
		if ok != c.quiero {
			t.Errorf("buscaPlaca(%q, %q) = %v, quiero %v", c.fabricante, c.modelo, ok, c.quiero)
			continue
		}
		if ok && (p.Ranuras != 2 || p.MaxGiB != 64) {
			t.Errorf("buscaPlaca(%q, %q) = %d ranuras / %d GiB, quiero 2 / 64",
				c.fabricante, c.modelo, p.Ranuras, p.MaxGiB)
		}
	}
}

// TestMarcaCanonica: el DMI y el catálogo escriben la marca distinto; ambos
// deben caer en la misma clave o las filas del catálogo nunca se aplican. Caso
// real: la ASUS TUF FX506HC reporta el fabricante como "ASUSTeK COMPUTER INC."
// mientras el catálogo lo guarda como "ASUS" (antes nunca coincidían).
func TestMarcaCanonica(t *testing.T) {
	pares := [][2]string{
		{"ASUSTeK COMPUTER INC.", "ASUS"},               // portátiles y placas ASUS
		{"Micro-Star International Co., Ltd.", "MSI"},   // placas/portátiles MSI
		{"Elitegroup Computer Systems CO.,LTD.", "ECS"}, // placas ECS
		{"Hewlett-Packard", "HP"},                       // HP viejo vs corto
		{"HP", "Hewlett-Packard"},                       // y al revés
		{"Super Micro Computer, Inc.", "Supermicro"},    // servidores Supermicro
		{"Hon Hai Precision Ind. Co.,Ltd.", "Foxconn"},  // Foxconn = Hon Hai
		{"Timi", "Xiaomi"},                              // portátiles Xiaomi reportan "Timi"
		{"Gigabyte Technology Co., Ltd.", "Gigabyte"},   // ya coincidía (default)
		{"ASRock", "ASRock"},                            // ya coincidía
		{"Biostar Group", "Biostar"},                    // ya coincidía
		{"Dell Inc.", "Dell"},                           // marca no divergente
		{"LENOVO", "Lenovo"},                            // marca no divergente
	}
	for _, p := range pares {
		dmi := marcaCanonica(normalizaPlaca(p[0]))
		cat := marcaCanonica(normalizaPlaca(p[1]))
		if dmi != cat {
			t.Errorf("marca DMI %q → %q, catálogo %q → %q: no coinciden", p[0], dmi, p[1], cat)
		}
	}

	// Microsoft (Surface) NO debe confundirse con MSI: el prefijo es "MICRO STAR",
	// no "MICRO". Regresión del arreglo original.
	if m := marcaCanonica(normalizaPlaca("Microsoft Corporation")); m == "MSI" {
		t.Errorf("Microsoft cayó en MSI (%q): el alias de MSI es demasiado amplio", m)
	}

	// La FX506HC del taller: firmware infla a 4 ranuras / 128 GiB; el catálogo
	// la corrige a 2 / 64. Sin la canonización de marca esto no pasaba.
	out := MemoryInfo{TotalSlots: 4, MaxCapacityBytes: 128 << 30}
	aplicaCatalogo(&out, BoardInfo{Vendor: "ASUSTeK COMPUTER INC.", Product: "FX506HC"})
	if out.TotalSlots != 2 || out.MaxCapacityBytes != 64<<30 {
		t.Errorf("FX506HC = %d ranuras / %d B, quiero 2 / %d B",
			out.TotalSlots, out.MaxCapacityBytes, int64(64)<<30)
	}
}

// TestCatalogoIntegro revisa el placas.json embebido: toda fila debe traer los
// cuatro datos, valores sensatos y su URL de origen (el catálogo solo admite
// datos VERIFICADOS contra la hoja de datos del fabricante), y ninguna clave
// puede repetirse — un duplicado significaría que dos filas se pisan.
func TestCatalogoIntegro(t *testing.T) {
	var placas []PlacaSpec
	if err := json.Unmarshal(placasEmbebidas, &placas); err != nil {
		t.Fatal("placas.json no es JSON válido:", err)
	}
	if len(placas) < 50 {
		t.Fatalf("el catálogo trae %d placas; se esperaban al menos 50", len(placas))
	}

	vistas := map[string]string{}
	for _, p := range placas {
		id := p.Fabricante + " " + p.Modelo
		if p.Fabricante == "" || p.Modelo == "" {
			t.Errorf("fila sin fabricante o modelo: %+v", p)
			continue
		}
		if p.Ranuras < 1 || p.Ranuras > 8 {
			t.Errorf("%s: %d ranuras, fuera de rango", id, p.Ranuras)
		}
		if p.MaxGiB < 1 || p.MaxGiB > 2048 {
			t.Errorf("%s: máximo %d GiB, fuera de rango", id, p.MaxGiB)
		}
		if !strings.HasPrefix(p.Fuente, "https://") {
			t.Errorf("%s: sin fuente verificable (%q)", id, p.Fuente)
		}
		k := clavePlaca(p.Fabricante, p.Modelo)
		if otra, dup := vistas[k]; dup {
			t.Errorf("clave duplicada %q: %q y %q se pisan", k, otra, id)
		}
		vistas[k] = id
	}
	t.Logf("catálogo: %d placas verificadas", len(placas))
}

// TestAplicaCatalogo: la ficha verificada pisa lo que dijo el firmware.
func TestAplicaCatalogo(t *testing.T) {
	// Lo que reporta hoy la A520M K V2: 4 ranuras y 128 GiB, ambos falsos.
	out := MemoryInfo{TotalSlots: 4, MaxCapacityBytes: 128 << 30}
	aplicaCatalogo(&out, BoardInfo{Vendor: "Gigabyte Technology Co., Ltd.", Product: "A520M K V2"})

	if out.TotalSlots != 2 {
		t.Errorf("ranuras = %d, quiero 2", out.TotalSlots)
	}
	if out.MaxCapacityBytes != 64<<30 {
		t.Errorf("capacidad máx = %d B, quiero %d B", out.MaxCapacityBytes, int64(64)<<30)
	}

	// Placa sin ficha: se respeta lo del firmware.
	otra := MemoryInfo{TotalSlots: 4, MaxCapacityBytes: 128 << 30}
	aplicaCatalogo(&otra, BoardInfo{Vendor: "ASUS", Product: "PRIME Z999M-INVENTADA"})
	if otra.TotalSlots != 4 || otra.MaxCapacityBytes != 128<<30 {
		t.Error("una placa fuera del catálogo no debe tocarse")
	}
}

// TestAjustaMaxCapacidad: la red de seguridad para las placas que no están en el
// catálogo. El firmware calcula el tope como ranuras × máximo por ranura, así
// que si infla las ranuras, infla el tope.
func TestAjustaMaxCapacidad(t *testing.T) {
	casos := []struct {
		nombre             string
		max                int64
		declaradas, reales int
		quiero             int64
	}{
		{"firmware infla 4 ranuras, hay 2", 128 << 30, 4, 2, 64 << 30},
		{"firmware dice la verdad", 64 << 30, 2, 2, 64 << 30},
		{"más ranuras reales que declaradas: no tocar", 128 << 30, 2, 4, 128 << 30},
		{"sin dato de capacidad", 0, 4, 2, 0},
		{"sin ranuras: no dividir entre cero", 128 << 30, 0, 2, 128 << 30},
	}
	for _, c := range casos {
		if got := ajustaMaxCapacidad(c.max, c.declaradas, c.reales); got != c.quiero {
			t.Errorf("%s: %d B, quiero %d B", c.nombre, got, c.quiero)
		}
	}
}
