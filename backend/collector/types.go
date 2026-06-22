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
}

type MemoryInfo struct {
	TotalBytes       int64       `json:"totalBytes"`
	UsableBytes      int64       `json:"usableBytes"`
	TotalSlots       int         `json:"totalSlots"`
	MaxCapacityBytes int64       `json:"maxCapacityBytes"`
	Soldered         bool        `json:"soldered"`
	Modules          []MemModule `json:"modules"`
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

	// S.M.A.R.T. (lo llena smartctl). smartAvailable=false si no reporta.
	SmartAvailable     bool  `json:"smartAvailable"`
	Health             string `json:"health"`
	WrittenBytes       int64 `json:"writtenBytes"`
	ReadBytes          int64 `json:"readBytes"`
	PowerOnHours       int   `json:"powerOnHours"`
	PowerCycles        int   `json:"powerCycles"`
	LifePercentUsed    int   `json:"lifePercentUsed"`
	ReallocatedSectors int   `json:"reallocatedSectors"`
}
