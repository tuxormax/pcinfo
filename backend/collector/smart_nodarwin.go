//go:build !darwin

package collector

// resolveSmartctlDarwin solo aplica en macOS (ver smart_darwin.go). Stub para
// que compile en el resto: en Windows/Linux resolveSmartctl() nunca la llama.
func resolveSmartctlDarwin() {}
