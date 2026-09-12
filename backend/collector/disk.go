package collector

import (
	"runtime"
	"strings"
	"sync"

	"github.com/jaypipes/ghw"
)

// collectDisks arma la lista de discos. [conSmart]=false devuelve solo lo
// inmediato (modelo, tamaño, uso) SIN consultar smartctl: es lo que pide la GUI
// en el primer arranque para pintar la pantalla al instante, y luego pide la
// salud aparte con CollectDiscos (ver /discos en main.go). Leer S.M.A.R.T. es lo
// único lento del inventario y depende de discos que pueden no contestar.
func collectDisks(conSmart bool, forzarUSB string) []DiskInfo {
	// macOS tiene colector propio: ghw no sirve ahí (soporte de bloques apagado
	// por una opción invertida, y `diskutil info` sin plazo se cuelga con discos
	// externos). Ver disk_darwin.go.
	if runtime.GOOS == "darwin" {
		return collectDisksDarwin(conSmart)
	}

	disks := []DiskInfo{}

	info, err := ghw.Block()
	if err != nil || info == nil {
		warn("block", err)
		return disks
	}

	for _, d := range info.Disks {
		if skipDisk(d.Name, d.SizeBytes) {
			continue
		}
		ctrl := strings.ToLower(d.StorageController.String())
		drive := strings.ToLower(d.DriveType.String())

		di := DiskInfo{
			Name:      deviceName(d.Name),
			Model:     strings.TrimSpace(d.Model),
			Vendor:    cleanDMI(d.Vendor),
			SizeBytes: int64(d.SizeBytes),
			Serial:    strings.TrimSpace(d.SerialNumber),
			Bus:       busName(ctrl, d.Name),
			// En Linux ghw lo trae de sysfs; en Windows siempre viene false y lo
			// corrige marcaMediosWindows con WMI (ghw no lo llena ahí).
			Removable:       d.IsRemovable,
			Type:            diskType(ctrl, drive),
			LifePercentUsed: -1,
		}
		// Uso del sistema de archivos: suma de las particiones montadas del disco.
		for _, p := range d.Partitions {
			if p == nil || p.MountPoint == "" {
				continue
			}
			if used, avail, ok := diskUsage(p.MountPoint); ok {
				di.UsedBytes += int64(used)
				di.AvailBytes += int64(avail)
			}
		}
		disks = append(disks, di)
	}

	// Marca qué discos son de medio removible (memoria USB, tarjeta SD) antes de
	// decidir a cuáles se les sondea el S.M.A.R.T.
	marcaMediosWindows(disks)

	// Dónde está enchufado cada disco (puerto SATA, M.2, USB). Va antes del
	// S.M.A.R.T. para que el dato esté ya en la primera fase del arranque, que
	// es la que pinta la pantalla.
	asignaPuertos(disks)

	if !conSmart {
		return disks
	}

	// Enriquecer con S.M.A.R.T. En Windows se descubre el dispositivo correcto vía
	// `smartctl --scan-open` y se empareja por serie (ghw da nombres que smartctl
	// no siempre acepta). En Linux, cada disco por su /dev/sdX, en PARALELO (cada
	// smartctl ya tiene su timeout) → total ≈ disco más lento, no la suma.
	if runtime.GOOS == "windows" {
		enrichSmartWindows(disks, forzarUSB)
	} else {
		var wg sync.WaitGroup
		for i := range disks {
			wg.Add(1)
			go func(di *DiskInfo) {
				defer wg.Done()
				readSmart(di)
			}(&disks[i])
		}
		wg.Wait()
	}

	// Con la salud ya leída, se redacta el veredicto y las explicaciones de cada
	// disco (pestaña "Discos"). Va aquí y no en el colector de S.M.A.R.T. porque
	// también hay que explicar los discos que NO lo reportan.
	for i := range disks {
		interpretaDisco(&disks[i])
	}
	return disks
}

// deviceName arma el nombre de dispositivo que ve el usuario y que se pasa a
// smartctl. En Linux ghw da "sda" → "/dev/sda". En Windows ghw ya da la ruta
// nativa "\\.\PHYSICALDRIVE0", que smartctl acepta tal cual; anteponerle
// "/dev/" la rompía (síntoma: "SIN SMART" en Windows).
func deviceName(name string) string {
	if runtime.GOOS == "windows" {
		return name
	}
	return "/dev/" + name
}

func skipDisk(name string, size uint64) bool {
	if size == 0 {
		return true
	}
	for _, p := range []string{"loop", "ram", "zram", "sr", "fd", "dm-", "md"} {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

func busName(ctrl, name string) string {
	switch {
	case strings.Contains(ctrl, "nvme"):
		return "nvme"
	case strings.Contains(ctrl, "virtio"):
		return "virtio"
	case strings.Contains(ctrl, "mmc"):
		return "mmc"
	case strings.HasPrefix(name, "sd"), strings.Contains(ctrl, "scsi"), strings.Contains(ctrl, "ide"), strings.Contains(ctrl, "ata"):
		return "sata"
	default:
		return ctrl
	}
}

func diskType(ctrl, drive string) string {
	if strings.Contains(ctrl, "nvme") {
		return "NVMe SSD"
	}
	switch drive {
	case "ssd":
		return "SATA SSD"
	case "hdd":
		return "HDD"
	default:
		if drive == "" || drive == "unknown" {
			return ""
		}
		return strings.ToUpper(drive)
	}
}
