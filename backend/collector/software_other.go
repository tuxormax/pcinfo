//go:build !windows && !linux

package collector

import (
	"fmt"
	"runtime"
)

// El inventario de software solo está implementado en Windows y Linux, que son
// las plataformas de entrega de PCInfo.
func collectSoftware() SoftwareReport {
	return SoftwareReport{
		OS:     runtime.GOOS,
		Items:  []SoftwareItem{},
		Reason: "El inventario de software no está disponible en " + runtime.GOOS + ".",
	}
}

// quitaAppx: quitar apps de la Tienda es exclusivo de Windows.
func quitaAppx(_ string) error { return fmt.Errorf("esta operación solo está disponible en Windows") }
