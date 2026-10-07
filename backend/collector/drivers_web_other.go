//go:build !windows

package collector

import (
	"context"
	"fmt"
)

func instalaPaqueteWeb(_ context.Context, _ DriverWeb, _ string) error {
	return fmt.Errorf("instalar controladores del fabricante solo está disponible en Windows")
}
