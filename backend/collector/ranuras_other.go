//go:build !windows && !linux

package collector

// En otros sistemas (macOS, BSD) no hay lectura de ranuras: el inventario se
// queda con lo que sí se puede leer. Ver ranuras.go.
func ranurasFirmware() []ExpansionSlot     { return nil }
func puertosSataSistema() []SataPort       { return nil }
func enrichPuertosDiscos(disks []DiskInfo) {}
