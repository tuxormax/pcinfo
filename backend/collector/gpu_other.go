//go:build !windows

package collector

// windowsGPUCards solo aplica en Windows; en Linux las GPU salen de ghw (PCI).
// Stub para que compile en todas las plataformas.
func windowsGPUCards() []GPUCard { return []GPUCard{} }
