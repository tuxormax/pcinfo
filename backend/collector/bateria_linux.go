//go:build linux

package collector

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// En Linux la batería la publica el propio kernel en /sys/class/power_supply.
// Están los mismos números que usa Windows (capacidad de fábrica, capacidad
// actual, ciclos, carga) salvo el HISTORIAL: Windows lo guarda semana a semana y
// Linux no lleva ese registro, así que esa parte de la pestaña queda vacía aquí.
const rutaPowerSupply = "/sys/class/power_supply"

func collectBattery() BatteryReport {
	rep := BatteryReport{
		OS:        "linux",
		Supported: true,
		Source:    "Kernel de Linux (" + rutaPowerSupply + ")",
		Generated: time.Now().Format("2006-01-02 15:04"),
	}

	entradas, err := os.ReadDir(rutaPowerSupply)
	if err != nil {
		rep.Reason = "No se pudo leer el estado de la batería: " + err.Error()
		return rep
	}
	sort.Slice(entradas, func(i, j int) bool { return entradas[i].Name() < entradas[j].Name() })

	for _, e := range entradas {
		dir := filepath.Join(rutaPowerSupply, e.Name())
		switch leeSys(dir, "type") {
		case "Battery":
			rep.Batteries = append(rep.Batteries, bateriaSysfs(dir, e.Name()))
			// power_now es el consumo REAL del equipo en este instante (µW).
			// Solo vale mientras va con batería: enchufado marca 0 o la carga.
			if leeSys(dir, "status") == "Discharging" {
				if w := numSys(dir, "power_now"); w > 0 {
					rep.WattsTypicalMW = int(w / 1000)
				}
			}
		case "Mains", "USB":
			if v := leeSys(dir, "online"); v != "" {
				rep.OnACKnown = true
				rep.OnAC = rep.OnAC || v == "1"
			}
		}
	}

	// Con el consumo de ahora mismo se puede decir cuánto aguanta. No es la
	// estimación histórica de Windows (Linux no guarda ese registro): es lo que
	// duraría SI se siguiera gastando al ritmo de este momento.
	if rep.WattsTypicalMW > 0 && len(rep.Batteries) > 0 {
		b := rep.Batteries[0]
		if b.FullMWh > 0 {
			rep.RuntimeFullMin = b.FullMWh * 60 / rep.WattsTypicalMW
		}
		if b.RemainingMWh > 0 {
			rep.RuntimeNowMin = b.RemainingMWh * 60 / rep.WattsTypicalMW
		}
	}

	rep.Available = true
	if len(rep.Batteries) > 0 {
		rep.Reason = "Linux no guarda el historial de capacidad semana a semana " +
			"como Windows, así que aquí solo se ve el estado de hoy."
	}
	return rep
}

// bateriaSysfs lee UNA batería. Los portátiles reportan la energía de dos formas
// distintas según el firmware: en energía (energy_*, µWh) o en carga (charge_*,
// µAh) que hay que multiplicar por el voltaje para obtener energía.
func bateriaSysfs(dir, nombre string) BatteryItem {
	b := BatteryItem{
		Name: primero(leeSys(dir, "model_name"), nombre),
		// model_name es la referencia de la pieza (el kernel la saca del ACPI):
		// es con lo que se pide un repuesto.
		Model:         leeSys(dir, "model_name"),
		Manufacturer:  leeSys(dir, "manufacturer"),
		Serial:        leeSys(dir, "serial_number"),
		Chemistry:     leeSys(dir, "technology"),
		ChargePercent: -1,
		CycleCount:    -1,
	}
	if v := numSys(dir, "voltage_min_design"); v > 0 {
		b.VoltageMV = int(v / 1000)
	} else if v := numSys(dir, "voltage_now"); v > 0 {
		b.VoltageMV = int(v / 1000)
	}

	b.DesignMWh = microWhAmWh(numSys(dir, "energy_full_design"))
	b.FullMWh = microWhAmWh(numSys(dir, "energy_full"))
	b.RemainingMWh = microWhAmWh(numSys(dir, "energy_now"))
	if b.DesignMWh == 0 && b.FullMWh == 0 {
		v := numSys(dir, "voltage_min_design")
		if v == 0 {
			v = numSys(dir, "voltage_now")
		}
		b.DesignMWh = cargaAmWh(numSys(dir, "charge_full_design"), v)
		b.FullMWh = cargaAmWh(numSys(dir, "charge_full"), v)
		b.RemainingMWh = cargaAmWh(numSys(dir, "charge_now"), v)
	}

	if v := leeSys(dir, "capacity"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			b.ChargePercent = n
		}
	}
	if v := leeSys(dir, "cycle_count"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			b.CycleCount = n
		} else if err == nil {
			// El kernel pone 0 cuando el firmware no lo informa.
			b.CycleCount = 0
		}
	}

	switch leeSys(dir, "status") {
	case "Charging":
		b.State = EstadoCargando
	case "Discharging":
		b.State = EstadoDescargando
	case "Full":
		b.State = EstadoLlena
	case "Not charging":
		b.State = EstadoConectada
	}
	return b
}

// microWhAmWh pasa de µWh (lo que publica el kernel) a mWh (lo que usa el
// informe de Windows, para que ambos sistemas hablen en la misma unidad).
func microWhAmWh(v int64) int { return int(v / 1000) }

// cargaAmWh convierte carga (µAh) × voltaje (µV) en mWh.
func cargaAmWh(carga, voltaje int64) int {
	if carga <= 0 || voltaje <= 0 {
		return 0
	}
	return int(carga / 1000 * voltaje / 1_000_000)
}

func leeSys(dir, archivo string) string {
	b, err := os.ReadFile(filepath.Join(dir, archivo))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func numSys(dir, archivo string) int64 {
	n, err := strconv.ParseInt(leeSys(dir, archivo), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func primero(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
