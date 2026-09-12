//go:build darwin

package collector

import (
	"context"
	"encoding/json"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// spDisplays es la respuesta de `system_profiler -json SPDisplaysDataType`.
type spDisplays struct {
	Items []struct {
		Name   string `json:"_name"`
		Model  string `json:"sppci_model"`            // "Apple M4"
		Vendor string `json:"spdisplays_vendor"`      // "sppci_vendor_Apple"
		Bus    string `json:"sppci_bus"`              // "spdisplays_builtin" / "spdisplays_pcie_device"
		Cores  string `json:"sppci_cores"`            // núcleos de GPU (Apple Silicon)
		VRAM   string `json:"spdisplays_vram"`        // Mac Intel con GPU dedicada
		VRAMSh string `json:"spdisplays_vram_shared"` // gráfica integrada Intel
	} `json:"SPDisplaysDataType"`
}

// darwinGPUCards lee las gráficas con system_profiler: en darwin `ghw` no
// implementa GPU (devuelve error) y la ficha quedaba vacía.
//
// ⛔ En Apple Silicon la GPU va dentro del SoC y comparte la RAM del sistema
// (memoria unificada): NO hay VRAM propia que informar, así que se deja en 0 y
// la GUI no pinta la fila. Poner ahí los 16 GB del equipo sería inventar una
// memoria de vídeo que no existe como tal.
func darwinGPUCards() []GPUCard {
	cards := []GPUCard{}
	datos := system_profilerJSON("SPDisplaysDataType")
	if len(datos) == 0 {
		return cards
	}
	var sp spDisplays
	if err := json.Unmarshal(datos, &sp); err != nil {
		warn("system_profiler SPDisplaysDataType", err)
		return cards
	}
	for _, it := range sp.Items {
		c := GPUCard{
			Vendor:  limpiaClaveSP(it.Vendor, "sppci_vendor_"),
			Product: primero(strings.TrimSpace(it.Model), strings.TrimSpace(it.Name)),
		}
		// Los núcleos de GPU son un dato que solo dan los Apple Silicon y que no
		// tiene hueco propio en la ficha: se añaden al nombre, que es donde el
		// usuario los va a buscar ("Apple M4 (10 núcleos)").
		if n, err := strconv.Atoi(strings.TrimSpace(it.Cores)); err == nil && n > 0 {
			c.Product += " (" + strconv.Itoa(n) + " núcleos de GPU)"
		}
		if v := vramBytesSP(primero(it.VRAM, it.VRAMSh)); v > 0 {
			c.MemoryBytes = v
		}
		if c.Product != "" || c.Vendor != "" {
			cards = append(cards, c)
		}
	}
	return cards
}

// system_profilerJSON ejecuta system_profiler con plazo. Es la herramienta de
// inventario de macOS y algunos apartados tardan, así que nunca se llama sin
// límite (SPApplicationsDataType es el peor, varios segundos).
func system_profilerJSON(tipo string) []byte {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "system_profiler", "-json", tipo).Output()
	if err != nil {
		warn("system_profiler "+tipo, err)
		return nil
	}
	return out
}

// limpiaClaveSP quita el prefijo interno con el que system_profiler devuelve
// algunos valores ("sppci_vendor_Apple" → "Apple").
func limpiaClaveSP(v, prefijo string) string {
	v = strings.TrimSpace(v)
	return strings.TrimPrefix(v, prefijo)
}

func primero(vs ...string) string {
	for _, v := range vs {
		if s := strings.TrimSpace(v); s != "" {
			return s
		}
	}
	return ""
}

// vramBytesSP convierte el texto de VRAM de system_profiler ("1536 MB", "4 GB")
// a bytes. Solo aparece en Mac Intel; en Apple Silicon viene vacío.
func vramBytesSP(v string) int64 {
	v = strings.TrimSpace(v)
	if v == "" {
		return 0
	}
	partes := strings.Fields(v)
	n, err := strconv.ParseFloat(partes[0], 64)
	if err != nil || n <= 0 {
		return 0
	}
	mult := int64(1)
	if len(partes) > 1 {
		switch strings.ToUpper(partes[1]) {
		case "MB":
			mult = 1024 * 1024
		case "GB":
			mult = 1024 * 1024 * 1024
		case "KB":
			mult = 1024
		}
	}
	return int64(n) * mult
}
