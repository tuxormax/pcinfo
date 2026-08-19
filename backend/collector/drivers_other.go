//go:build !windows

package collector

import (
	"context"
	"fmt"
	"runtime"
)

// El módulo de controladores es SOLO WINDOWS a propósito: en Linux los
// controladores forman parte del kernel y los instala la distribución, así que
// respaldarlos y restaurarlos no tiene sentido — restaurar los de otro equipo
// solo podría romper el arranque.
//
// Las redes WiFi de Linux (NetworkManager) SÍ se podrían respaldar; se dejó
// fuera del alcance de esta entrega. Ver la tabla de paridad de la memoria.

func estadoControladores() DriversReport {
	return DriversReport{
		OS:        runtime.GOOS,
		Supported: false,
		Elevated:  isElevated(),
		Drivers:   []DriverItem{},
		Wifi:      []WifiProfile{},
		Reason: "El respaldo de controladores es exclusivo de Windows: en " + runtime.GOOS +
			" los controladores vienen en el kernel y los gestiona la propia distribución.",
	}
}

func respaldaControladores(_ context.Context, _ string) error { return noDisponible() }
func restauraControladores(_ context.Context, _ string) error { return noDisponible() }
func respaldaWifi(_ context.Context, _ string) error          { return noDisponible() }
func restauraWifi(_ context.Context, _ string) error          { return noDisponible() }

func noDisponible() error {
	return fmt.Errorf("esta operación solo está disponible en Windows")
}
