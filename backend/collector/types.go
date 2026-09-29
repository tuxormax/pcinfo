// Package collector reúne el inventario de hardware de la máquina y lo expone
// con la MISMA forma que pcinfo/lib/models/hardware.dart (el contrato de datos).
// Los tags `json` deben coincidir EXACTAMENTE con los nombres que parsea Flutter.
package collector

// HardwareInfo es la raíz del JSON que consume la GUI: GET /hardware.
type HardwareInfo struct {
	System SystemInfo `json:"system"`
	CPU    CPUInfo    `json:"cpu"`
	Board  BoardInfo  `json:"board"`
	Memory MemoryInfo `json:"memory"`
	GPU    GPUInfo    `json:"gpu"`
	Disks  []DiskInfo `json:"disks"`
	Diag   DiagInfo   `json:"diag"`
}

// DiagInfo son diagnósticos del propio recolector para que la GUI dé mensajes
// ACCIONABLES cuando algo no se pudo leer. Caso clave: en Windows el S.M.A.R.T.
// necesita que el backend corra ELEVADO y que smartctl.exe esté empaquetado; si
// falta cualquiera de los dos, todos los discos salen "SIN SMART". Con estos
// campos la GUI distingue "falta permiso de administrador" (ofrece reintentar
// elevado) de "falta smartctl.exe" (reinstalar) de una limitación real (USB/RAID).
type DiagInfo struct {
	OS            string `json:"os"`            // runtime.GOOS: "windows" | "linux" | ...
	Elevated      bool   `json:"elevated"`      // ¿corre con token de admin/root?
	SmartctlFound bool   `json:"smartctlFound"` // ¿se localizó el ejecutable de smartctl?
}

type SystemInfo struct {
	Hostname string `json:"hostname"`
	Distro   string `json:"distro"`
	Kernel   string `json:"kernel"`
	Arch     string `json:"arch"`
	Desktop  string `json:"desktop"`
}

type CPUInfo struct {
	Vendor  string  `json:"vendor"`
	Model   string  `json:"model"`
	Cores   int     `json:"cores"`
	Threads int     `json:"threads"`
	BaseMhz float64 `json:"baseMhz"`
	MaxMhz  float64 `json:"maxMhz"`
}

type BoardInfo struct {
	Vendor      string `json:"vendor"`
	Product     string `json:"product"`
	Version     string `json:"version"`
	BiosVendor  string `json:"biosVendor"`
	BiosVersion string `json:"biosVersion"`
	BiosDate    string `json:"biosDate"`
	FormFactor  string `json:"formFactor"`

	// Ranuras de expansión (PCIe, M.2) y puertos SATA de la placa. Contestan la
	// pregunta de taller "¿le cabe otro disco / otra tarjeta?", que no se puede
	// responder mirando solo lo que ya está conectado. Ver ranuras.go.
	Slots     []ExpansionSlot `json:"slots"`
	SataPorts []SataPort      `json:"sataPorts"`

	// SataDeclared son los conectores SATA que la placa trae SEGÚN EL CATÁLOGO
	// (hoja de datos). 0 = placa no catalogada. Se separa de len(SataPorts)
	// porque el chipset presenta más puertos de los que la placa cablea: este
	// equipo de pruebas expone 12 puertos ata y tiene 6 conectores.
	SataDeclared int `json:"sataDeclared"`

	// SataUsed son los conectores SATA con un disco puesto AHORA (dato del
	// sistema, disponible en cualquier placa esté o no catalogada).
	SataUsed int `json:"sataUsed"`

	// PortsSource dice de dónde salió la cuenta de ranuras/puertos:
	// "catalogo" (hoja de datos, dato de fábrica), "firmware" (SMBIOS, miente en
	// algunas placas) o "" si no se pudo leer nada. La GUI lo usa para avisar,
	// igual que hace con las ranuras de RAM.
	PortsSource string `json:"portsSource"`

	// PortsNote es la advertencia de la hoja de datos sobre compartición de
	// carriles ("al usar el M.2 se apagan los SATA 5 y 6"). Vacía si la placa no
	// está catalogada o no tiene salvedades.
	PortsNote string `json:"portsNote"`
}

// ExpansionSlot es una ranura de expansión de la placa: PCIe (para gráfica,
// controladora, red…) o M.2 (para un SSD NVMe o SATA). Lo importante es si está
// LIBRE: es lo que decide si se le puede ampliar algo al equipo.
type ExpansionSlot struct {
	Label string `json:"label"` // serigrafía: "PCIEX16_1", "M.2_1"
	Kind  string `json:"kind"`  // "pcie" | "m2" | "m2wifi" | "pci" | "otra"
	Spec  string `json:"spec"`  // "PCIe 3.0 x16", "M.2 llave M (PCIe x4 / NVMe)"

	// State: "ocupada" | "libre" | "" (no se pudo saber). Se distingue "libre"
	// de "no se sabe" A PROPÓSITO: decirle a un técnico que una ranura está
	// libre cuando en realidad no se leyó el dato le hace cargar con una tarjeta
	// que no va a poder poner.
	State  string `json:"state"`
	UsedBy string `json:"usedBy"` // qué la ocupa, si se pudo averiguar
	Source string `json:"source"` // "catalogo" | "firmware"
}

// SataPort es un conector SATA de la placa y qué disco cuelga de él.
type SataPort struct {
	Label  string `json:"label"`  // "SATA 1" (orden del sistema, no serigrafía)
	Used   bool   `json:"used"`   //
	UsedBy string `json:"usedBy"` // "/dev/sda — KINGSTON SA400S37240G"
}

type MemoryInfo struct {
	TotalBytes       int64 `json:"totalBytes"`
	UsableBytes      int64 `json:"usableBytes"`
	TotalSlots       int   `json:"totalSlots"`
	MaxCapacityBytes int64 `json:"maxCapacityBytes"`
	Soldered         bool  `json:"soldered"`
	// SlotsVerified indica que ranuras y capacidad máx. vienen del catálogo de
	// placas verificado (dato de fábrica). Si es false, salen del firmware
	// SMBIOS, que en algunas placas MIENTE (ranuras fantasma) → la GUI lo marca
	// con un aviso "según firmware" para no engañar en placas no catalogadas.
	SlotsVerified bool        `json:"slotsVerified"`
	SolderedBytes int64       `json:"solderedBytes"` // RAM soldada (0 si no hay); con Soldered=false es un equipo mixto
	Modules       []MemModule `json:"modules"`
}

type MemModule struct {
	Label      string `json:"label"`
	Location   string `json:"location"`
	Vendor     string `json:"vendor"`
	SizeBytes  int64  `json:"sizeBytes"`
	Type       string `json:"type"`
	SpeedMhz   int    `json:"speedMhz"`
	FormFactor string `json:"formFactor"`
}

type GPUInfo struct {
	Cards []GPUCard `json:"cards"`
}

type GPUCard struct {
	Vendor      string `json:"vendor"`
	Product     string `json:"product"`
	Driver      string `json:"driver"`
	MemoryBytes int64  `json:"memoryBytes"`
}

type DiskInfo struct {
	Name      string `json:"name"`
	Model     string `json:"model"`
	Vendor    string `json:"vendor"`
	SizeBytes int64  `json:"sizeBytes"`
	Type      string `json:"type"`
	Serial    string `json:"serial"`
	Bus       string `json:"bus"`

	// Port es DÓNDE está enchufado el disco: "SATA 3", "M.2_1", "USB". Sale de
	// la ruta del dispositivo en el sistema (sysfs en Linux, PnP/WMI en
	// Windows), no del firmware. Vacío si no se pudo averiguar.
	Port string `json:"port"`

	// Removable=true cuando el MEDIO es extraíble (memoria USB, tarjeta SD,
	// lector). Esos no reportan S.M.A.R.T. y tardan en contestar que no, así que
	// no se les sondea salvo que el usuario lo pida a mano. Un SSD/NVMe dentro de
	// un gabinete USB NO es removible para Windows: a ese sí se le lee.
	Removable bool `json:"removable"`

	// Uso del sistema de archivos (suma de las particiones montadas del disco).
	// 0 si el disco no tiene particiones montadas (secundario sin montar, etc.).
	UsedBytes  int64 `json:"usedBytes"`
	AvailBytes int64 `json:"availBytes"`

	// S.M.A.R.T. (lo llena smartctl). smartAvailable=false si no reporta.
	SmartAvailable     bool   `json:"smartAvailable"`
	Health             string `json:"health"`
	WrittenBytes       int64  `json:"writtenBytes"`
	ReadBytes          int64  `json:"readBytes"`
	PowerOnHours       int    `json:"powerOnHours"`
	PowerCycles        int    `json:"powerCycles"`
	LifePercentUsed    int    `json:"lifePercentUsed"`
	ReallocatedSectors int    `json:"reallocatedSectors"`

	// Salud derivada de los atributos SMART, no solo del PASSED/FAILED global:
	// "good" | "warning" | "fail" (vacío si no hay SMART). Issues es la lista de
	// problemas detectados con su consecuencia, para el modal de la GUI.
	HealthLevel string      `json:"healthLevel"`
	Issues      []DiskIssue `json:"issues"`

	// La misma salud, EXPLICADA como en la pestaña de batería: una frase que
	// dice qué hacer y las notas que traducen cada número a lenguaje normal.
	// Las arma interpretaDisco (disco_salud.go).
	Verdict string `json:"verdict"`
	Notes   []Nota `json:"notes"`
}

// DiskIssue es un problema concreto detectado en el disco: qué es y qué implica.
type DiskIssue struct {
	Severity string `json:"severity"` // "warning" | "fail"
	Title    string `json:"title"`    // nombre corto del problema
	Detail   string `json:"detail"`   // qué significa + consecuencia
}
