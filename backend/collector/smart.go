package collector

import (
	"encoding/json"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// ataAttr es una fila de la tabla de atributos S.M.A.R.T. ATA.
type ataAttr struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Value int    `json:"value"` // valor normalizado (0-100), no el raw
	Raw   struct {
		Value int64 `json:"value"`
	} `json:"raw"`
}

// smartJSON mapea los campos de `smartctl --json -a` que nos interesan.
type smartJSON struct {
	SmartStatus *struct {
		Passed bool `json:"passed"`
	} `json:"smart_status"`
	PowerOnTime struct {
		Hours int `json:"hours"`
	} `json:"power_on_time"`
	PowerCycleCount  int `json:"power_cycle_count"`
	LogicalBlockSize int `json:"logical_block_size"`

	NVMeLog *struct {
		DataUnitsWritten int64 `json:"data_units_written"`
		DataUnitsRead    int64 `json:"data_units_read"`
		PowerOnHours     int   `json:"power_on_hours"`
		PowerCycles      int   `json:"power_cycles"`
		PercentageUsed   int   `json:"percentage_used"`
	} `json:"nvme_smart_health_information_log"`

	ATA *struct {
		Table []ataAttr `json:"table"`
	} `json:"ata_smart_attributes"`
}

// 1 "data unit" NVMe = 1000 sectores de 512 B = 512000 bytes.
const nvmeDataUnit = 1000 * 512

// readSmart llena los campos S.M.A.R.T. de di ejecutando smartctl. smartctl
// devuelve un código de salida con flags (≠0 aunque el JSON sea válido), por
// eso parseamos stdout sin importar el error del proceso.
func readSmart(di *DiskInfo) {
	out, _ := exec.Command("smartctl", "--json", "-a", di.Name).Output()
	if len(out) == 0 {
		return
	}
	var s smartJSON
	if err := json.Unmarshal(out, &s); err != nil {
		warn("smartctl", err)
		return
	}
	if s.SmartStatus == nil && s.NVMeLog == nil && s.ATA == nil {
		return // el dispositivo no reporta SMART (USB/VM/sin permisos)
	}
	di.SmartAvailable = true

	if s.SmartStatus != nil {
		if s.SmartStatus.Passed {
			di.Health = "PASSED"
		} else {
			di.Health = "FAILED"
		}
	}

	switch {
	case s.NVMeLog != nil:
		di.WrittenBytes = s.NVMeLog.DataUnitsWritten * nvmeDataUnit
		di.ReadBytes = s.NVMeLog.DataUnitsRead * nvmeDataUnit
		di.PowerOnHours = s.NVMeLog.PowerOnHours
		di.PowerCycles = s.NVMeLog.PowerCycles
		di.LifePercentUsed = s.NVMeLog.PercentageUsed
	case s.ATA != nil:
		di.PowerOnHours = s.PowerOnTime.Hours
		di.PowerCycles = s.PowerCycleCount
		lbs := int64(s.LogicalBlockSize)
		if lbs == 0 {
			lbs = 512
		}
		for _, a := range s.ATA.Table {
			switch a.ID {
			case 5: // Reallocated_Sector_Ct
				di.ReallocatedSectors = int(a.Raw.Value)
			case 241: // escrituras totales del host
				di.WrittenBytes = hostBytes(di.Model, a.Name, a.Raw.Value, lbs)
			case 242: // lecturas totales del host
				di.ReadBytes = hostBytes(di.Model, a.Name, a.Raw.Value, lbs)
			}
		}
		di.LifePercentUsed = ataLifeUsed(s.ATA.Table)
		// Fallback: si el top-level vino en 0, leer de los atributos 9 y 12.
		if di.PowerOnHours == 0 || di.PowerCycles == 0 {
			for _, a := range s.ATA.Table {
				if di.PowerOnHours == 0 && a.ID == 9 {
					di.PowerOnHours = int(a.Raw.Value)
				}
				if di.PowerCycles == 0 && a.ID == 12 {
					di.PowerCycles = int(a.Raw.Value)
				}
			}
		}
	}
}

// reUnit extrae un múltiplo embebido en el nombre del atributo, p. ej.
// "Host_Writes_32MiB" → (32, MiB), "NAND_Writes_1GiB" → (1, GiB).
var reUnit = regexp.MustCompile(`(\d*)\s*(gib|mib|gb|mb)`)

// hostUnitsBytes mapea modelos cuyo controlador reporta 241/242 en una unidad
// que el preset de smartmontools NO le aplica al modelo concreto. Copiado del
// propio drivedb.h: la familia ADATA SU Silicon Motion usa 32 MiB por unidad,
// pero el regex del preset no cubre variantes como "SU800NS38".
var modelHostUnit = []struct {
	re    *regexp.Regexp
	bytes int64
}{
	{regexp.MustCompile(`(?i)ADATA[ _]SU[689]\d\d`), 32 * 1024 * 1024},
}

// hostBytes calcula los bytes de escrituras/lecturas del host: primero un
// override por modelo (firmware que miente bajo un nombre estándar), si no, la
// unidad deducida del nombre del atributo.
func hostBytes(model, name string, raw, lbs int64) int64 {
	for _, o := range modelHostUnit {
		if o.re.MatchString(model) {
			return raw * o.bytes
		}
	}
	return attrToBytes(name, raw, lbs)
}

// attrToBytes convierte el raw de un atributo a bytes decidiendo la unidad por
// el NOMBRE (los controladores reportan en GiB/GB/MiB/sectores bajo nombres
// distintos). Soporta múltiplos embebidos ("..._32MiB"). Ej.: Kingston usa
// "Lifetime_Writes_GiB" (×1024³); la mayoría "Total_LBAs_Written" (×sector).
func attrToBytes(name string, raw, lbs int64) int64 {
	n := strings.ToLower(name)
	if m := reUnit.FindStringSubmatch(n); m != nil {
		mult := int64(1)
		if m[1] != "" {
			if v, err := strconv.ParseInt(m[1], 10, 64); err == nil {
				mult = v
			}
		}
		switch m[2] {
		case "gib":
			return raw * mult * 1024 * 1024 * 1024
		case "gb":
			return raw * mult * 1000 * 1000 * 1000
		case "mib":
			return raw * mult * 1024 * 1024
		case "mb":
			return raw * mult * 1000 * 1000
		}
	}
	if strings.Contains(n, "lba") || strings.Contains(n, "sector") {
		return raw * lbs
	}
	return raw * lbs
}

// ataLifeUsed devuelve el % de vida CONSUMIDA del SSD (-1 si no aplica/HDD).
// Decide por nombre del atributo: los "life left/remaining/wearout" usan el
// valor normalizado (% restante → 100-valor); los "...life_used" dan el % usado
// directo. Wear_Leveling_Count es la aproximación de respaldo.
func ataLifeUsed(table []ataAttr) int {
	for _, a := range table {
		n := strings.ToLower(a.Name)
		switch {
		case strings.Contains(n, "life_used"), strings.Contains(n, "rated_life_used"),
			strings.Contains(n, "lifetime_used"), strings.Contains(n, "perc_rated_life"):
			return clampPct(int(a.Raw.Value))
		case strings.Contains(n, "ssd_life_left"), strings.Contains(n, "life_left"),
			strings.Contains(n, "life_remain"), strings.Contains(n, "lifetime_remain"),
			strings.Contains(n, "remaining_life"), strings.Contains(n, "media_wearout"):
			return clampPct(100 - a.Value)
		}
	}
	for _, a := range table { // respaldo: desgaste por wear leveling
		n := strings.ToLower(a.Name)
		if strings.Contains(n, "wear_leveling") || strings.Contains(n, "wearout") {
			return clampPct(100 - a.Value)
		}
	}
	return -1
}

func clampPct(v int) int {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}
