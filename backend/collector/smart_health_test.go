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
		{"solo CRC → advertencia (cable)", ataTable(map[int]int64{199: 120}), "warning", 1},
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
