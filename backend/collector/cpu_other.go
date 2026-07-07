//go:build !windows

package collector

// enrichCPU solo aplica en Windows; en Linux la frecuencia sale de cpufreq
// (ver collectCPU). Stub para que compile en todas las plataformas.
func enrichCPU(_ *CPUInfo) {}
