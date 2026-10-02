//go:build darwin

package collector

import (
	"context"
	"fmt"
	"runtime"
)

// El módulo "Tienda Windows" es SOLO WINDOWS: la Microsoft Store y los
// paquetes .appx/.msix no existen en ningún otro sistema.

func estadoTienda() TiendaInfo {
	return TiendaInfo{
		OS:        runtime.GOOS,
		Supported: false,
		Elevated:  isElevated(),
		Reason: "Instalar apps de la Microsoft Store es exclusivo de Windows: en " +
			runtime.GOOS + " no existen ni la Tienda ni los paquetes .appx/.msix.",
	}
}

func buscaTienda(_ string) ([]AppTienda, error) { return nil, noDisponibleTienda() }

func instalaApps(_ context.Context, _ []AppTienda, _, _ string, _ bool) error {
	return noDisponibleTienda()
}

func instalaCarpeta(_ context.Context, _, _ string, _ bool) error {
	return noDisponibleTienda()
}

func noDisponibleTienda() error {
	return fmt.Errorf("esta operación solo está disponible en Windows")
}
