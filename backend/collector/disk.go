package collector

import (
	"runtime"
	"strings"

	"github.com/jaypipes/ghw"
)

func collectDisks() []DiskInfo {
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
			Name:            deviceName(d.Name),
			Model:           strings.TrimSpace(d.Model),
			Vendor:          cleanDMI(d.Vendor),
			SizeBytes:       int64(d.SizeBytes),
			Serial:          strings.TrimSpace(d.SerialNumber),
			Bus:             busName(ctrl, d.Name),
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
		// Enriquecer con S.M.A.R.T. (smartctl --json).
		readSmart(&di)
		disks = append(disks, di)
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
