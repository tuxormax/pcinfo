package collector

import (
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
			Name:            "/dev/" + d.Name,
			Model:           strings.TrimSpace(d.Model),
			Vendor:          cleanDMI(d.Vendor),
			SizeBytes:       int64(d.SizeBytes),
			Serial:          strings.TrimSpace(d.SerialNumber),
			Bus:             busName(ctrl, d.Name),
			Type:            diskType(ctrl, drive),
			LifePercentUsed: -1,
		}
		// Enriquecer con S.M.A.R.T. (smartctl --json).
		readSmart(&di)
		disks = append(disks, di)
	}
	return disks
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
