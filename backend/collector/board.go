package collector

import "github.com/jaypipes/ghw"

func collectBoard() BoardInfo {
	var out BoardInfo

	if bb, err := ghw.Baseboard(); err == nil && bb != nil {
		out.Vendor = bb.Vendor
		out.Product = bb.Product
		out.Version = cleanDMI(bb.Version) // descarta "x.x" y similares
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
