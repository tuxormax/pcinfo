//go:build !darwin

package collector

// darwinSystem solo aplica en macOS (ver system_darwin.go). Stub para que
// compile en el resto de plataformas.
func darwinSystem(_ *SystemInfo) {}
