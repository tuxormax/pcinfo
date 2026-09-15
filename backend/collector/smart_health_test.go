package collector

import "testing"

// ataTable arma un smartJSON ATA con los atributos (id→raw) dados y estado SMART
// global PASSED, para probar evalDiskHealth.
func ataTable(attrs map[int]int64) smartJSON {
	var s smartJSON
	s.SmartStatus = &struct {
		Passed bool `json:"passed"`
	}{Passed: true}
	s.ATA = &struct {
		Table []ataAttr `json:"table"`
	}{}
	for id, raw := range attrs {
		a := ataAttr{ID: id}
		a.Raw.Value = raw
		s.ATA.Table = append(s.ATA.Table, a)
	}
	return s
}

func TestEvalDiskHealth(t *testing.T) {
	casos := []struct {
		nombre string
		s      smartJSON
		nivel  string
		nIss   int
	}{
		{"disco sano", ataTable(map[int]int64{5: 0, 197: 0, 199: 0}), "good", 0},
		{"sectores pendientes → peligro", ataTable(map[int]int64{197: 3}), "fail", 1},
		{"no corregibles → peligro", ataTable(map[int]int64{198: 1}), "fail", 1},
		{"reasignados → advertencia", ataTable(map[int]int64{5: 8}), "warning", 1},
		// CRC UltraDMA (199) ya NO se evalúa por raw>0: un tropiezo aislado del
		// cable/USB es normal. Sin que el disco defina un umbral real (caso de
		// ataTable, que no toca Value/Thresh), no debe avisar — ver
		// TestChequeoCRCUltraDMA para el caso donde SÍ cruza el umbral real.
		{"solo CRC sin umbral real → sano", ataTable(map[int]int64{199: 120}), "good", 0},
		{"pendientes + reasignados → peligro, 2 problemas",
			ataTable(map[int]int64{5: 4, 197: 2}), "fail", 2},
		// Los atributos ruidosos NO deben generar falso positivo.
		{"raw read/seek altos (Seagate) → sano",
			ataTable(map[int]int64{1: 200000000, 7: 5000000}), "good", 0},
	}
	for _, c := range casos {
		var di DiskInfo
		evalDiskHealth(&di, c.s)
		if di.HealthLevel != c.nivel {
			t.Errorf("%s: nivel=%q, quiero %q", c.nombre, di.HealthLevel, c.nivel)
		}
		if len(di.Issues) != c.nIss {
			t.Errorf("%s: %d problema(s), quiero %d", c.nombre, len(di.Issues), c.nIss)
		}
	}
}

func TestEvalDiskHealthSmartFailed(t *testing.T) {
	s := ataTable(map[int]int64{})
	s.SmartStatus.Passed = false // el disco se declara fallando
	var di DiskInfo
	evalDiskHealth(&di, s)
	if di.HealthLevel != "fail" {
		t.Errorf("SMART FAILED debe dar nivel fail, dio %q", di.HealthLevel)
	}
}

// TestChequeoCRCUltraDMA prueba el atributo 199 contra el criterio real de
// SMART (valor normalizado vs. umbral del propio disco), no solo raw>0: es el
// caso real que reportó tuxor — un HDD Toshiba en gabinete USB/JMicron con 1
// solo error CRC, que CrystalDiskInfo deja en "Bueno" porque el umbral que
// reporta ESE disco para este atributo es 0 (no crossable).
func TestChequeoCRCUltraDMA(t *testing.T) {
	casos := []struct {
		nombre        string
		value, thresh int
		raw           int64
		quieroAviso   bool
	}{
		{"disco no define umbral (Toshiba real) → sin aviso pese a raw>0", 200, 0, 1, false},
		{"valor por encima del umbral real → sin aviso", 80, 20, 5, false},
		{"valor cruzó el umbral real → aviso", 15, 20, 500, true},
	}
	for _, c := range casos {
		tabla := []ataAttr{{ID: idCRCUltraDMA, Value: c.value, Thresh: c.thresh}}
		tabla[0].Raw.Value = c.raw
		_, ok := chequeoCRCUltraDMA(tabla)
		if ok != c.quieroAviso {
			t.Errorf("%s: aviso=%v, quiero %v", c.nombre, ok, c.quieroAviso)
		}
	}
}

func TestEvalDiskHealthNVMe(t *testing.T) {
	var s smartJSON
	s.NVMeLog = &struct {
		DataUnitsWritten     int64 `json:"data_units_written"`
		DataUnitsRead        int64 `json:"data_units_read"`
		PowerOnHours         int   `json:"power_on_hours"`
		PowerCycles          int   `json:"power_cycles"`
		PercentageUsed       int   `json:"percentage_used"`
		CriticalWarning      int   `json:"critical_warning"`
		MediaErrors          int64 `json:"media_errors"`
		AvailableSpare       int   `json:"available_spare"`
		AvailableSpareThresh int   `json:"available_spare_threshold"`
	}{CriticalWarning: 4, AvailableSpare: 100, AvailableSpareThresh: 10}
	var di DiskInfo
	evalDiskHealth(&di, s)
	if di.HealthLevel != "fail" {
		t.Errorf("critical_warning NVMe debe dar fail, dio %q", di.HealthLevel)
	}
}
