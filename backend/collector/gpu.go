package collector

import (
	"os/exec"
	"strconv"
	"strings"

	"github.com/jaypipes/ghw"
)

func collectGPU() GPUInfo {
	out := GPUInfo{Cards: []GPUCard{}}

	info, err := ghw.GPU()
	if err != nil || info == nil {
		warn("gpu", err)
		return out
	}

	for _, gc := range info.GraphicsCards {
		card := GPUCard{}
		if gc.DeviceInfo != nil {
			if gc.DeviceInfo.Vendor != nil {
				card.Vendor = gc.DeviceInfo.Vendor.Name
			}
			if gc.DeviceInfo.Product != nil {
				card.Product = gc.DeviceInfo.Product.Name
			}
			card.Driver = gc.DeviceInfo.Driver
		}
		out.Cards = append(out.Cards, card)
	}

	// nvidia-smi completa versión de driver y VRAM real de las tarjetas NVIDIA
	// (ghw no da VRAM fiable, y >4GB se rompe en Windows/WMI).
	enrichNvidia(out.Cards)
	return out
}

func enrichNvidia(cards []GPUCard) {
	rows := nvidiaSmi()
	if len(rows) == 0 {
		return
	}
	i := 0
	for idx := range cards {
		if !strings.Contains(strings.ToUpper(cards[idx].Vendor), "NVIDIA") {
			continue
		}
		if i >= len(rows) {
			break
		}
		r := rows[i]
		i++
		if r.driver != "" {
			cards[idx].Driver = "nvidia " + r.driver
		}
		if r.memMiB > 0 {
			cards[idx].MemoryBytes = r.memMiB * 1024 * 1024
		}
		if cards[idx].Product == "" {
			cards[idx].Product = r.name
		}
	}
}

type nvRow struct {
	name   string
	driver string
	memMiB int64
}

func nvidiaSmi() []nvRow {
	out, err := exec.Command("nvidia-smi",
		"--query-gpu=name,driver_version,memory.total",
		"--format=csv,noheader,nounits").Output()
	if err != nil {
		return nil
	}
	var rows []nvRow
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		parts := strings.Split(line, ",")
		if len(parts) < 3 {
			continue
		}
		mem, _ := strconv.ParseInt(strings.TrimSpace(parts[2]), 10, 64)
		rows = append(rows, nvRow{
			name:   strings.TrimSpace(parts[0]),
			driver: strings.TrimSpace(parts[1]),
			memMiB: mem,
		})
	}
	return rows
}
