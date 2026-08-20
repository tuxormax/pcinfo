package collector

import (
	"regexp"
	"strings"

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
		out.BiosVendor = marcaBIOS(bios.Vendor)
		out.BiosVersion = bios.Version
		out.BiosDate = normalizaFechaBIOS(bios.Date)
	} else {
		warn("bios", err)
	}
	// Windows: ghw se queda con Win32_BIOS.Version, que NO es la versión del
	// BIOS. afinaBIOS la sustituye por la de verdad. En Linux no hace nada.
	afinaBIOS(&out)

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

// marcasBIOS acorta el nombre del fabricante del firmware. El DMI lo escribe
// como razón social completa ("American Megatrends International, LLC.") y en la
// ficha ocupa una línea entera para decir lo que se conoce por tres letras.
var marcasBIOS = []struct{ contiene, corto string }{
	{"american megatrends", "AMI"},
	{"insyde", "Insyde"},
	{"phoenix", "Phoenix"},
	{"award", "Award"},
	{"byosoft", "Byosoft"},
	{"lenovo", "Lenovo"},
	{"hewlett", "HP"},
	{"dell", "Dell"},
	{"apple", "Apple"},
	{"seabios", "SeaBIOS"},
	{"edk ii", "UEFI (EDK II)"},
}

// marcaBIOS devuelve el nombre corto del fabricante del BIOS, o el original si
// no está en la lista.
func marcaBIOS(v string) string {
	limpio := cleanDMI(v)
	l := strings.ToLower(limpio)
	for _, m := range marcasBIOS {
		if strings.Contains(l, m.contiene) {
			return m.corto
		}
	}
	return limpio
}

// reFechaUS reconoce la fecha del BIOS tal cual la publica el DMI: mm/dd/aaaa
// (el SMBIOS la define en formato de Estados Unidos).
var reFechaUS = regexp.MustCompile(`^(\d{1,2})/(\d{1,2})/(\d{4})$`)

// reFechaISO reconoce aaaa-mm-dd, que es como la dan algunos firmwares.
var reFechaISO = regexp.MustCompile(`^(\d{4})-(\d{2})-(\d{2})`)

// normalizaFechaBIOS deja la fecha del BIOS en dd/mm/aaaa, que es como se lee en
// español. Sin esto un "05/31/2017" del DMI se entiende al revés (31 de mayo se
// lee como 5 de marzo... o directamente como una fecha imposible). Si no se
// reconoce el formato se devuelve tal cual: mejor un dato crudo que ninguno.
func normalizaFechaBIOS(s string) string {
	s = strings.TrimSpace(s)
	if m := reFechaUS.FindStringSubmatch(s); m != nil {
		return dosDigitos(m[2]) + "/" + dosDigitos(m[1]) + "/" + m[3]
	}
	if m := reFechaISO.FindStringSubmatch(s); m != nil {
		return m[3] + "/" + m[2] + "/" + m[1]
	}
	return s
}

func dosDigitos(s string) string {
	if len(s) == 1 {
		return "0" + s
	}
	return s
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
