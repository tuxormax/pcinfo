//go:build !darwin

package collector

// collectDisksDarwin solo existe en macOS (ver disk_darwin.go: allí los discos
// salen de `diskutil`, no de ghw). Stub para que compile en el resto.
func collectDisksDarwin(_ bool) []DiskInfo { return nil }
