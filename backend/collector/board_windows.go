//go:build windows

package collector

import (
	"strings"

	"github.com/yusufpapurcu/wmi"
)

// win32BIOS son los campos de Win32_BIOS que valen la pena.
//
// ReleaseDate llega como CIM_DATETIME ("20170531000000.000000+000"). Se pide
// como string a propósito: si se declarara time.Time y el firmware trajera una
// fecha rara, la consulta ENTERA fallaría y perderíamos también la versión.
type win32BIOS struct {
	Manufacturer      string
	SMBIOSBIOSVersion string
	Version           string
	ReleaseDate       string
}

// afinaBIOS corrige en Windows lo que ghw deja mal.
//
// El problema: ghw usa Win32_BIOS.Version, que NO es la versión del BIOS sino
// un identificador OEM del estilo "LENOVO - 1" o "ALASKA - 1072009"; y no llena
// la fecha. Resultado en un Lenovo: "BIOS: LENOVO LENOVO - 1" y "Fecha BIOS:"
// vacía. La versión que el usuario ve en la pantalla de arranque y en el propio
// informe de Windows es SMBIOSBIOSVersion ("2JCN39WW"), con su ReleaseDate.
func afinaBIOS(b *BoardInfo) {
	var bios []win32BIOS
	q := "SELECT Manufacturer, SMBIOSBIOSVersion, Version, ReleaseDate FROM Win32_BIOS"
	if err := wmi.Query(q, &bios); err != nil {
		warn("wmi BIOS", err)
		return
	}
	if len(bios) == 0 {
		return
	}
	x := bios[0]

	if v := marcaBIOS(x.Manufacturer); v != "" {
		b.BiosVendor = v
	}
	// SMBIOSBIOSVersion es la buena. Si viniera vacía (rarísimo) se conserva la
	// que trajo ghw antes que quedarse sin nada.
	if v := cleanDMI(x.SMBIOSBIOSVersion); v != "" {
		b.BiosVersion = v
	} else if v := cleanDMI(x.Version); v != "" && b.BiosVersion == "" {
		b.BiosVersion = v
	}
	if f := fechaCIM(x.ReleaseDate); f != "" {
		b.BiosDate = f
	}
}

// fechaCIM convierte un CIM_DATETIME ("20170531000000.000000+000") en
// "31/05/2017". Devuelve "" si no tiene esa pinta.
func fechaCIM(s string) string {
	s = strings.TrimSpace(s)
	if len(s) < 8 {
		return ""
	}
	a, m, d := s[0:4], s[4:6], s[6:8]
	for _, c := range a + m + d {
		if c < '0' || c > '9' {
			return ""
		}
	}
	if a == "0000" || m == "00" || d == "00" {
		return ""
	}
	return d + "/" + m + "/" + a
}
