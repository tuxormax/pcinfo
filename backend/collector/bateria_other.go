//go:build !windows && !linux

package collector

import "runtime"

// La batería solo se lee en Windows y Linux, que son las plataformas de entrega
// de PCInfo.
func collectBattery() BatteryReport {
	return BatteryReport{
		OS:     runtime.GOOS,
		Reason: "La lectura de la batería no está disponible en " + runtime.GOOS + ".",
	}
}
