//go:build windows

package collector

import (
	"strconv"
	"strings"

	"github.com/yusufpapurcu/wmi"
	"golang.org/x/sys/windows/registry"
)

// win32OS mapea los campos de Win32_OperatingSystem que nos interesan.
type win32OS struct {
	Caption     string // "Microsoft Windows 11 Pro"
	Version     string // "10.0.26100"
	BuildNumber string // "26100"
}

// windowsSystem llena el nombre comercial y la compilación de Windows. WMI da el
// Caption ("Microsoft Windows 11 Pro") y la versión NT; el registro aporta el
// release comercial (DisplayVersion = "24H2") y la revisión de build (UBR =
// 1742). Resultado: Distro="Windows 11 Pro 24H2", Kernel="10.0.26100.1742".
func windowsSystem(s *SystemInfo) {
	caption, version, build := "", "", ""
	var osi []win32OS
	q := "SELECT Caption, Version, BuildNumber FROM Win32_OperatingSystem"
	if err := wmi.Query(q, &osi); err != nil {
		warn("wmi OperatingSystem", err)
	} else if len(osi) > 0 {
		caption = strings.TrimSpace(osi[0].Caption)
		version = strings.TrimSpace(osi[0].Version)
		build = strings.TrimSpace(osi[0].BuildNumber)
	}

	// Registro: release comercial (24H2) y revisión de compilación (.1742).
	display, ubr := "", ""
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE,
		`SOFTWARE\Microsoft\Windows NT\CurrentVersion`, registry.QUERY_VALUE); err == nil {
		defer k.Close()
		if v, _, e := k.GetStringValue("DisplayVersion"); e == nil && v != "" {
			display = v // Win10 2004+ / Win11: "22H2", "24H2"
		} else if v, _, e := k.GetStringValue("ReleaseId"); e == nil {
			display = v // Win10 más viejo: "1909"
		}
		if u, _, e := k.GetIntegerValue("UBR"); e == nil {
			ubr = strconv.FormatUint(u, 10)
		}
		if build == "" {
			if b, _, e := k.GetStringValue("CurrentBuildNumber"); e == nil {
				build = b
			}
		}
	}

	// Nombre comercial: quitar "Microsoft ". Windows 11 sigue reportando NT 10.0
	// y algunas builds ponen "Windows 10" en el Caption → corregir por build.
	name := strings.TrimPrefix(caption, "Microsoft ")
	if bn, _ := strconv.Atoi(build); bn >= 22000 && strings.Contains(name, "Windows 10") {
		name = strings.Replace(name, "Windows 10", "Windows 11", 1)
	}
	if name == "" {
		name = "Windows"
	}
	if display != "" {
		name += " " + display
	}
	s.Distro = strings.TrimSpace(name)

	// Kernel/compilación: versión NT + revisión → "10.0.26100.1742".
	kernel := version
	if kernel == "" && build != "" {
		kernel = "10.0." + build
	}
	if ubr != "" && kernel != "" {
		kernel += "." + ubr
	}
	s.Kernel = kernel
}
