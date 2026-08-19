//go:build windows

package collector

import (
	"strings"

	"github.com/yusufpapurcu/wmi"
)

// win32DiskDrive mapea Win32_DiskDrive: la única fuente que dice si el MEDIO de
// un disco es removible. ghw no lo trae en Windows (deja IsRemovable en false
// siempre), y sin ese dato una memoria USB es indistinguible de un SSD metido en
// un gabinete externo.
type win32DiskDrive struct {
	DeviceID      string // \\.\PHYSICALDRIVE0 — el mismo nombre que da ghw
	MediaType     string // "Removable Media" | "Fixed hard disk media" | "External hard disk media"
	InterfaceType string // "USB", "SCSI", "IDE"...
}

// marcaMediosWindows marca qué discos son de MEDIO REMOVIBLE (memoria USB,
// tarjeta SD, lector) y cuáles cuelgan de USB. Se usa para no perder segundos
// preguntándole el S.M.A.R.T. a una memoria USB —que no lo reporta y tarda en
// contestar que no— sin dejar de leérselo a un SSD/NVMe en gabinete externo, que
// Windows presenta como disco fijo o externo, NO como medio removible (misma
// distinción que hace CrystalDiskInfo).
func marcaMediosWindows(disks []DiskInfo) {
	var drives []win32DiskDrive
	q := "SELECT DeviceID, MediaType, InterfaceType FROM Win32_DiskDrive"
	if err := wmi.Query(q, &drives); err != nil {
		warn("wmi DiskDrive", err)
		return
	}
	for _, d := range drives {
		idx := -1
		for i := range disks {
			if strings.EqualFold(strings.TrimSpace(disks[i].Name), strings.TrimSpace(d.DeviceID)) {
				idx = i
				break
			}
		}
		if idx < 0 {
			continue
		}
		disks[idx].Removable = strings.Contains(strings.ToLower(d.MediaType), "removable")
		if strings.EqualFold(strings.TrimSpace(d.InterfaceType), "USB") {
			disks[idx].Bus = "usb" // ghw reporta "scsi" para todo lo que cuelga de USB
		}
	}
}
