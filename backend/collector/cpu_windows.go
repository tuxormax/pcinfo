//go:build windows

package collector

import "github.com/yusufpapurcu/wmi"

// win32Processor mapea la frecuencia nominal del CPU. MaxClockSpeed es la
// frecuencia BASE rotulada (MHz), no el turbo/boost (WMI no lo da).
type win32Processor struct {
	MaxClockSpeed uint32
}

// enrichCPU (Windows) llena la frecuencia base desde WMI cuando no vino de otra
// fuente. No requiere elevación.
func enrichCPU(out *CPUInfo) {
	if out.BaseMhz > 0 {
		return
	}
	var ps []win32Processor
	if err := wmi.Query("SELECT MaxClockSpeed FROM Win32_Processor", &ps); err != nil {
		warn("wmi Processor", err)
		return
	}
	if len(ps) > 0 && ps[0].MaxClockSpeed > 0 {
		out.BaseMhz = float64(ps[0].MaxClockSpeed)
	}
}
