package collector

import "testing"

// TestBuscaPlaca: el DMI escribe el fabricante y el modelo de formas distintas
// según la placa; todas deben caer en la misma ficha del catálogo.
func TestBuscaPlaca(t *testing.T) {
	casos := []struct {
		fabricante, modelo string
		quiero             bool
	}{
		{"Gigabyte Technology Co., Ltd.", "A520M K V2", true},  // como lo reporta WMI/DMI
		{"GIGABYTE", "A520M K V2 (rev. 1.1)", true},            // con revisión de placa
		{"gigabyte technology co., ltd.", "a520m k v2", true},  // minúsculas
		{"Gigabyte Technology Co., Ltd.", "A520M DS3H", false}, // otra placa: sin ficha
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
	aplicaCatalogo(&otra, BoardInfo{Vendor: "ASUS", Product: "PRIME B450M-A"})
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
