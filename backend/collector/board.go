package collector

import "github.com/jaypipes/ghw"

func collectBoard() BoardInfo {
	var out BoardInfo

	if bb, err := ghw.Baseboard(); err == nil && bb != nil {
		out.Vendor = bb.Vendor
		out.Product = bb.Product
		out.Version = bb.Version
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

	// formFactor (ATX/Micro-ATX/…) no lo expone DMI de forma fiable; queda ""
	// (gap conocido, la GUI muestra "Desconocido").
	return out
}
