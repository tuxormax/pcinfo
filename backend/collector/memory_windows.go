//go:build windows

package collector

import (
	"github.com/yusufpapurcu/wmi"
)

// win32PhysicalMemory = una ranura OCUPADA (Win32_PhysicalMemory).
type win32PhysicalMemory struct {
	DeviceLocator        string
	BankLabel            string
	Manufacturer         string
	Capacity             uint64
	Speed                uint32
	ConfiguredClockSpeed uint32
	SMBIOSMemoryType     uint16
	MemoryType           uint16
	FormFactor           uint16
	PartNumber           string
}

// win32MemoryArray = el arreglo físico (Win32_PhysicalMemoryArray): total de
// ranuras y capacidad máxima soportada por la placa.
type win32MemoryArray struct {
	MemoryDevices uint32
	MaxCapacity   uint32 // KB (topado ~2 TB en sistemas viejos)
	MaxCapacityEx uint64 // KB (valor real en sistemas modernos)
}

// enrichMemory (Windows) llena ranuras/módulos vía WMI. No requiere elevación
// para Win32_PhysicalMemory; corre igual como servicio (LocalSystem) o usuario.
func enrichMemory(out *MemoryInfo) {
	var arrays []win32MemoryArray
	q := "SELECT MemoryDevices, MaxCapacity, MaxCapacityEx FROM Win32_PhysicalMemoryArray"
	if err := wmi.Query(q, &arrays); err != nil {
		warn("wmi PhysicalMemoryArray", err)
	} else {
		for _, a := range arrays {
			if int(a.MemoryDevices) > out.TotalSlots {
				out.TotalSlots = int(a.MemoryDevices)
			}
			var maxBytes int64
			if a.MaxCapacityEx > 0 {
				maxBytes = int64(a.MaxCapacityEx) * 1024
			} else if a.MaxCapacity > 0 {
				maxBytes = int64(a.MaxCapacity) * 1024
			}
			if maxBytes > out.MaxCapacityBytes {
				out.MaxCapacityBytes = maxBytes
			}
		}
	}

	var mods []win32PhysicalMemory
	q = "SELECT DeviceLocator, BankLabel, Manufacturer, Capacity, Speed, " +
		"ConfiguredClockSpeed, SMBIOSMemoryType, MemoryType, FormFactor, PartNumber " +
		"FROM Win32_PhysicalMemory"
	if err := wmi.Query(q, &mods); err != nil {
		warn("wmi PhysicalMemory", err)
		return
	}
	for _, m := range mods {
		if m.Capacity == 0 {
			continue
		}
		speed := int(m.ConfiguredClockSpeed)
		if speed == 0 {
			speed = int(m.Speed)
		}
		ff := memFormFactor(m.FormFactor)
		out.Modules = append(out.Modules, MemModule{
			Label:      m.DeviceLocator,
			Location:   m.BankLabel,
			Vendor:     cleanDMI(m.Manufacturer),
			SizeBytes:  int64(m.Capacity),
			Type:       memType(m.SMBIOSMemoryType, m.MemoryType),
			SpeedMhz:   speed,
			FormFactor: ff,
		})
		if m.FormFactor == 11 { // "Row of chips" → soldada
			out.Soldered = true
		}
	}
}

// memType traduce el tipo de memoria SMBIOS a texto ("DDR4", "DDR5", ...). Los
// sistemas modernos reportan el valor real en SMBIOSMemoryType; MemoryType (el
// enum viejo de Win32) queda de respaldo.
func memType(smbios, legacy uint16) string {
	table := map[uint16]string{
		20: "DDR", 21: "DDR2", 22: "DDR2 FB-DIMM", 24: "DDR3", 26: "DDR4",
		27: "LPDDR", 28: "LPDDR2", 29: "LPDDR3", 30: "LPDDR4",
		32: "HBM", 33: "HBM2", 34: "DDR5", 35: "LPDDR5", 36: "HBM3",
	}
	if s, ok := table[smbios]; ok {
		return s
	}
	if s, ok := table[legacy]; ok {
		return s
	}
	return ""
}

// memFormFactor traduce el enum FormFactor de Win32_PhysicalMemory.
func memFormFactor(ff uint16) string {
	switch ff {
	case 8:
		return "DIMM"
	case 12:
		return "SODIMM"
	case 11:
		return "Row Of Chips"
	default:
		return ""
	}
}
