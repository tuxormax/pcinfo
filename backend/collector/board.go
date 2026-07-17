package collector

import (
	"regexp"

	"github.com/jaypipes/ghw"
)

func collectBoard() BoardInfo {
	var out BoardInfo

	if bb, err := ghw.Baseboard(); err == nil && bb != nil {
		out.Vendor = bb.Vendor
		out.Product = bb.Product
		out.Version = revisionPlaca(bb.Product, bb.Version)
	} else {
		warn("baseboard", err)
	}

	if bios, err := ghw.BIOS(); err == nil && bios != nil {
		out.BiosVendor = bios.Vendor
		out.BiosVersion = bios.Version
		out.BiosDate = bios.Date
	} else {
		warn("bios", err)
	}

	// Form factor: DMI no expone ATX/Micro-ATX de la PLACA, pero sí el tipo de
	// CHASIS (Desktop/Tower/Notebook/…) vía ghw.Chassis (SMBIOS tipo 3 en Linux,
	// WMI en Windows). Es el dato real más cercano; antes quedaba "".
	if ch, err := ghw.Chassis(); err == nil && ch != nil {
		if ff := cleanDMI(ch.TypeDescription); ff != "" {
			out.FormFactor = ff
		}
	} else {
		warn("chassis", err)
	}
	return out
}

// reRevParen captura la revisión escrita como sufijo "(rev. 1.1)" / "(Rev 1.0)"
// dentro del nombre del producto (patrón típico de Gigabyte/ASRock).
var reRevParen = regexp.MustCompile(`(?i)\(\s*rev\.?\s*([0-9][0-9a-z.]*)\s*\)`)

// reRevCola captura una revisión pegada al final del nombre, tipo "H310M DS2 2.0"
// o "B450M 1.1": un token "N.N" al cierre de la cadena.
var reRevCola = regexp.MustCompile(`(\d+\.\d+)\s*$`)

// revisionPlaca deduce la revisión de la placa. El firmware la reparte en varios
// lados: el campo Version del DMI (ASUS/ASRock suelen poner "Rev X.0x"), un
// sufijo "(rev. 1.1)" en el producto, o un token de versión al final del nombre
// ("H310M DS2 2.0"). Gigabyte deja Version en "x.x" (basura, la descarta
// cleanDMI); por eso, si no hay Version útil, se busca la revisión en el propio
// nombre del producto —que es donde el usuario la ve escrita—.
func revisionPlaca(product, version string) string {
	if v := cleanDMI(version); v != "" {
		return v
	}
	if m := reRevParen.FindStringSubmatch(product); m != nil {
		return m[1]
	}
	if m := reRevCola.FindStringSubmatch(product); m != nil {
		return m[1]
	}
	return ""
}
