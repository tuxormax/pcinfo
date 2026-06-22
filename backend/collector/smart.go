package collector

import (
	"encoding/json"
	"os/exec"
)

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
		Table []struct {
			ID  int    `json:"id"`
			Raw struct {
				Value int64 `json:"value"`
			} `json:"raw"`
		} `json:"table"`
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
			case 241: // Total_LBAs_Written
				di.WrittenBytes = a.Raw.Value * lbs
			case 242: // Total_LBAs_Read
				di.ReadBytes = a.Raw.Value * lbs
			}
		}
	}
}
