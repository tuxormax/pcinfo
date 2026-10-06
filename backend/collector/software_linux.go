//go:build linux

package collector

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Software instalado en Linux. Se consulta lo que haya disponible y se suma:
// el gestor de paquetes de la distribución (dpkg o rpm) más flatpak y snap.
// Si una herramienta no está instalada simplemente no aporta nada; el módulo
// solo falla si NINGUNA responde.
//
// "Quién lo instaló": en Debian/Ubuntu `apt-mark showmanual` distingue lo que
// alguien pidió expresamente de las dependencias que arrastró el sistema. Es la
// única fuente fiable para agrupar la exportación en "lo que trae el sistema" y
// "lo que instaló el usuario". En rpm no hay equivalente directo, así que ahí
// todo lo del gestor cuenta como del sistema salvo flatpak y snap.

func collectSoftware() SoftwareReport {
	rep := SoftwareReport{
		OS:    "linux",
		Items: []SoftwareItem{},
	}
	fuentes := []string{}

	manuales := paquetesManuales()

	if items, ok := leeDpkg(manuales); ok {
		fuentes = append(fuentes, "dpkg (paquetes del sistema)")
		rep.Items = append(rep.Items, items...)
	} else if items, ok := leeRpm(); ok {
		fuentes = append(fuentes, "rpm (paquetes del sistema)")
		rep.Items = append(rep.Items, items...)
	}
	if items, ok := leeFlatpak(); ok {
		fuentes = append(fuentes, "flatpak")
		rep.Items = append(rep.Items, items...)
	}
	if items, ok := leeSnap(); ok {
		fuentes = append(fuentes, "snap")
		rep.Items = append(rep.Items, items...)
	}

	rep.Available = len(fuentes) > 0
	rep.Source = strings.Join(fuentes, ", ")
	if !rep.Available {
		rep.Source = "ninguna"
		rep.Reason = "No se encontró ningún gestor de paquetes conocido (dpkg, rpm, flatpak o snap)."
	}
	return rep
}

// paquetesManuales devuelve los paquetes que apt marca como instalados a
// petición del usuario. Conjunto vacío si no es una distribución con apt.
func paquetesManuales() map[string]bool {
	out := map[string]bool{}
	salida, err := ejecuta("apt-mark", "showmanual")
	if err != nil {
		return out
	}
	for _, l := range strings.Split(salida, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			out[l] = true
		}
	}
	return out
}

func leeDpkg(manuales map[string]bool) ([]SoftwareItem, bool) {
	if _, err := exec.LookPath("dpkg-query"); err != nil {
		return nil, false
	}
	salida, err := ejecuta("dpkg-query", "-W",
		"-f=${Package}\t${Version}\t${Maintainer}\t${Installed-Size}\t${Architecture}\t${db:Status-Status}\n")
	if err != nil && strings.TrimSpace(salida) == "" {
		return nil, false
	}
	out := []SoftwareItem{}
	for _, linea := range strings.Split(salida, "\n") {
		c := strings.Split(linea, "\t")
		if len(c) < 5 || strings.TrimSpace(c[0]) == "" {
			continue
		}
		// Un paquete desconfigurado o solo con la configuración residual no está
		// realmente instalado: no debe aparecer en la lista.
		if len(c) >= 6 && strings.TrimSpace(c[5]) != "installed" {
			continue
		}
		manual := manuales[strings.TrimSpace(c[0])]
		out = append(out, SoftwareItem{
			Name:      limpiaTexto(c[0]),
			Version:   limpiaTexto(c[1]),
			Publisher: limpiaTexto(c[2]),
			SizeMB:    entero(c[3]) / 1024, // dpkg lo da en KiB
			Arch:      limpiaTexto(c[4]),
			Source:    "dpkg",
			Kind:      KindPrograma,
			System:    !manual,
			Origin:    origenSegun(manual),
		})
	}
	return out, len(out) > 0
}

func leeRpm() ([]SoftwareItem, bool) {
	if _, err := exec.LookPath("rpm"); err != nil {
		return nil, false
	}
	salida, err := ejecuta("rpm", "-qa", "--qf",
		"%{NAME}\t%{VERSION}-%{RELEASE}\t%{VENDOR}\t%{SIZE}\t%{ARCH}\t%{INSTALLTIME}\n")
	if err != nil && strings.TrimSpace(salida) == "" {
		return nil, false
	}
	out := []SoftwareItem{}
	for _, linea := range strings.Split(salida, "\n") {
		c := strings.Split(linea, "\t")
		if len(c) < 5 || strings.TrimSpace(c[0]) == "" {
			continue
		}
		it := SoftwareItem{
			Name:      limpiaTexto(c[0]),
			Version:   limpiaTexto(c[1]),
			Publisher: limpiaTexto(c[2]),
			SizeMB:    entero(c[3]) / (1024 * 1024), // rpm lo da en bytes
			Arch:      limpiaTexto(c[4]),
			Source:    "rpm",
			Kind:      KindPrograma,
			System:    true,
			Origin:    OrigenSistema,
		}
		if len(c) >= 6 {
			if seg := entero(c[5]); seg > 0 {
				it.Installed = time.Unix(seg, 0).Format("2006-01-02")
			}
		}
		out = append(out, it)
	}
	return out, len(out) > 0
}

func leeFlatpak() ([]SoftwareItem, bool) {
	if _, err := exec.LookPath("flatpak"); err != nil {
		return nil, false
	}
	salida, err := ejecuta("flatpak", "list", "--app", "--columns=name,version,application,origin,size")
	if err != nil && strings.TrimSpace(salida) == "" {
		return nil, false
	}
	out := []SoftwareItem{}
	for _, linea := range strings.Split(salida, "\n") {
		c := strings.Split(linea, "\t")
		if len(c) < 3 || strings.TrimSpace(c[0]) == "" {
			continue
		}
		out = append(out, SoftwareItem{
			Name:      limpiaTexto(c[0]),
			Version:   limpiaTexto(c[1]),
			Publisher: limpiaTexto(c[2]),
			Source:    "flatpak",
			Kind:      KindTienda,
			Origin:    OrigenUsuario,
		})
	}
	return out, len(out) > 0
}

func leeSnap() ([]SoftwareItem, bool) {
	if _, err := exec.LookPath("snap"); err != nil {
		return nil, false
	}
	salida, err := ejecuta("snap", "list")
	if err != nil && strings.TrimSpace(salida) == "" {
		return nil, false
	}
	out := []SoftwareItem{}
	for i, linea := range strings.Split(salida, "\n") {
		if i == 0 { // encabezado: Name Version Rev Tracking Publisher Notes
			continue
		}
		c := strings.Fields(linea)
		if len(c) < 2 {
			continue
		}
		it := SoftwareItem{
			Name:    limpiaTexto(c[0]),
			Version: limpiaTexto(c[1]),
			Source:  "snap",
			Kind:    KindTienda,
			Origin:  OrigenUsuario,
		}
		if len(c) >= 5 {
			it.Publisher = limpiaTexto(c[4])
		}
		// Los snap "base" y "snapd" son la infraestructura, no apps del usuario.
		if len(c) >= 6 && strings.Contains(c[5], "base") {
			it.Kind = KindComponente
			it.System = true
			it.Origin = OrigenSistema
		}
		out = append(out, it)
	}
	return out, len(out) > 0
}

func origenSegun(delUsuario bool) string {
	if delUsuario {
		return OrigenUsuario
	}
	return OrigenSistema
}

func entero(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

// quitaAppx: quitar apps de la Tienda es exclusivo de Windows.
func quitaAppx(_ string) error { return fmt.Errorf("esta operación solo está disponible en Windows") }
