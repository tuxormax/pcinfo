//go:build darwin

package collector

import (
	"encoding/json"
	"strings"
)

// spHardware es la respuesta de `system_profiler -json SPHardwareDataType`.
type spHardware struct {
	Items []struct {
		MachineName    string `json:"machine_name"`     // "Mac mini"
		MachineModel   string `json:"machine_model"`    // "Mac16,10"
		ModelNumber    string `json:"model_number"`     // "MU9D3E/A"
		SerialNumber   string `json:"serial_number"`    // serie del equipo
		ChipType       string `json:"chip_type"`        // "Apple M4"
		BootROMVersion string `json:"boot_rom_version"` // firmware, el "BIOS" de un Mac
		PhysicalMemory string `json:"physical_memory"`  // "16 GB"
	} `json:"SPHardwareDataType"`
}

// placaDarwin llena la ficha del equipo en un Mac.
//
// ⛔ Un Mac NO tiene DMI/SMBIOS, así que `ghw.Baseboard()`, `ghw.BIOS()` y
// `ghw.Chassis()` devuelven error y la ficha quedaba ENTERA en blanco. Apple
// tampoco publica un modelo de placa: lo que hay es el modelo del EQUIPO
// ("Mac mini", identificador "Mac16,10") y la versión del firmware de arranque
// (boot ROM), que es el equivalente honesto del BIOS.
//
// Las ranuras y los puertos siguen en "no aplica": eso no se toca aquí.
func placaDarwin(out *BoardInfo) {
	datos := system_profilerJSON("SPHardwareDataType")
	if len(datos) == 0 {
		return
	}
	var sp spHardware
	if err := json.Unmarshal(datos, &sp); err != nil {
		warn("system_profiler SPHardwareDataType", err)
		return
	}
	if len(sp.Items) == 0 {
		return
	}
	h := sp.Items[0]

	out.Vendor = "Apple"
	out.Product = strings.TrimSpace(h.MachineName)
	// El identificador de modelo es lo que de verdad distingue un equipo de otro
	// ("Mac16,10"); va en la fila de versión/revisión, como la revisión de placa
	// en un PC.
	out.Version = strings.TrimSpace(h.MachineModel)

	out.BiosVendor = "Apple"
	out.BiosVersion = strings.TrimSpace(h.BootROMVersion)
	// Apple no publica fecha de firmware: la fila se queda vacía en vez de
	// inventarse una.
}
