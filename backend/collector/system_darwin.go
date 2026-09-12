//go:build darwin

package collector

import "strings"

// darwinSystem llena el sistema operativo en un Mac. No hay /etc/os-release ni
// registro: el nombre comercial y la compilación salen de `sw_vers` y el kernel
// de `uname -r`. Se arma "macOS 26.5.1 (compilación 25F80)" para que la ficha
// diga lo mismo que en Linux y Windows: nombre comercial + build.
func darwinSystem(s *SystemInfo) {
	nombre := strings.TrimSpace(cmdOut("sw_vers", "-productName"))
	if nombre == "" {
		nombre = "macOS"
	}
	version := strings.TrimSpace(cmdOut("sw_vers", "-productVersion"))
	build := strings.TrimSpace(cmdOut("sw_vers", "-buildVersion"))

	distro := nombre
	if version != "" {
		distro += " " + version
	}
	if build != "" {
		distro += " (compilación " + build + ")"
	}
	s.Distro = distro
	s.Kernel = strings.TrimSpace(cmdOut("uname", "-r"))
}
