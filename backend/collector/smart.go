package collector

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// drivedbAdd es la base de datos por modelo de PCInfo (formato oficial de
// smartmontools) embebida en el binario. Se materializa a un archivo temporal
// una sola vez y se pasa a smartctl con `-B +<archivo>` para que prependa estas
// entradas a su drivedb.h interno (ganan prioridad, caen al built-in si no
// matchean). Así un modelo cuyo regex oficial no cubra su variante recibe los
// presets correctos (unidad de 241/242, vida) sin tocar el sistema.
//
//go:embed drivedb-add.h
var drivedbAdd []byte

var (
	drivedbOnce sync.Once
	drivedbPath string // ruta del archivo temporal; "" si no se pudo crear
)

// drivedbArg devuelve el argumento `-B +<ruta>` para smartctl, materializando
// el drivedb-add.h embebido la primera vez. Si no se puede escribir el temporal,
// devuelve nil y smartctl corre con su drivedb interno (override por modelo en
// modelHostUnit sigue como respaldo).
func drivedbArg() []string {
	drivedbOnce.Do(func() {
		f, err := os.CreateTemp("", "pcinfo-drivedb-*.h")
		if err != nil {
			warn("drivedb temp", err)
			return
		}
		if _, err := f.Write(drivedbAdd); err != nil {
			warn("drivedb write", err)
			f.Close()
			return
		}
		f.Close()
		drivedbPath = f.Name()
	})
	if drivedbPath == "" {
		return nil
	}
	return []string{"-B", "+" + drivedbPath}
}

var (
	smartctlOnce  sync.Once
	smartctlPath  = "smartctl" // Linux/PATH; en Windows se resuelve junto al exe.
	smartctlFound bool         // ¿se localizó el ejecutable? (para el diagnóstico)
)

// resolveSmartctl localiza el ejecutable de smartctl una sola vez. En Linux está
// en el PATH (dependencia smartmontools del .deb). En Windows NO hay smartctl en
// el PATH, así que el instalador lo empaqueta junto al backend; lo buscamos en la
// carpeta del propio ejecutable (síntoma si falta: "SIN SMART" en todos los discos).
func resolveSmartctl() {
	smartctlOnce.Do(func() {
		if runtime.GOOS != "windows" {
			if _, err := exec.LookPath("smartctl"); err == nil {
				smartctlFound = true
			}
			return
		}
		exe, err := os.Executable()
		if err != nil {
			return
		}
		cand := filepath.Join(filepath.Dir(exe), "smartctl.exe")
		if _, err := os.Stat(cand); err == nil {
			smartctlPath = cand
			smartctlFound = true
		}
	})
}

// smartctlBin devuelve la ruta al ejecutable de smartctl.
func smartctlBin() string {
	resolveSmartctl()
	return smartctlPath
}

// smartctlAvailable indica si se localizó smartctl (para el diagnóstico de la GUI:
// si es false, el aviso "SIN SMART" se debe a que falta el ejecutable, no a permisos).
func smartctlAvailable() bool {
	resolveSmartctl()
	return smartctlFound
}

// ataAttr es una fila de la tabla de atributos S.M.A.R.T. ATA.
type ataAttr struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Value int    `json:"value"` // valor normalizado (0-100), no el raw
	Raw   struct {
		Value int64 `json:"value"`
	} `json:"raw"`
}

// smartJSON mapea los campos de `smartctl --json -a` que nos interesan.
type smartJSON struct {
	SerialNumber string `json:"serial_number"`
	ModelName    string `json:"model_name"`

	SmartStatus *struct {
		Passed bool `json:"passed"`
	} `json:"smart_status"`
	PowerOnTime struct {
		Hours int `json:"hours"`
	} `json:"power_on_time"`
	PowerCycleCount  int `json:"power_cycle_count"`
	LogicalBlockSize int `json:"logical_block_size"`

	NVMeLog *struct {
		DataUnitsWritten     int64 `json:"data_units_written"`
		DataUnitsRead        int64 `json:"data_units_read"`
		PowerOnHours         int   `json:"power_on_hours"`
		PowerCycles          int   `json:"power_cycles"`
		PercentageUsed       int   `json:"percentage_used"`
		CriticalWarning      int   `json:"critical_warning"`
		MediaErrors          int64 `json:"media_errors"`
		AvailableSpare       int   `json:"available_spare"`
		AvailableSpareThresh int   `json:"available_spare_threshold"`
	} `json:"nvme_smart_health_information_log"`

	ATA *struct {
		Table []ataAttr `json:"table"`
	} `json:"ata_smart_attributes"`
}

// 1 "data unit" NVMe = 1000 sectores de 512 B = 512000 bytes.
const nvmeDataUnit = 1000 * 512

// runSmartctl ejecuta `smartctl --json -a <device>` (con `-d <type>` si se
// indica) y devuelve stdout. Timeout duro: en algunos discos (USB, NVMe/SATA
// tras ciertos controladores) smartctl puede tardar o colgarse; sin límite,
// /hardware excedería el timeout de la GUI. smartctl sale con código ≠0 aunque
// el JSON sea válido (flags), por eso ignoramos el error del proceso.
func runSmartctl(device, dtype string) []byte {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	args := drivedbArg()
	if dtype != "" {
		args = append(args, "-d", dtype)
	}
	args = append(args, "--json", "-a", device)
	cmd := exec.CommandContext(ctx, smartctlBin(), args...)
	ocultaVentana(cmd) // Windows: sin ventana de consola negra
	out, _ := cmd.Output()
	return out
}

// readSmart llena los campos S.M.A.R.T. de di consultando smartctl con su
// nombre de dispositivo (Linux: /dev/sdX). En Windows se usa enrichSmartWindows.
func readSmart(di *DiskInfo) {
	parseSmartInto(di, runSmartctl(di.Name, ""))
}

// parseSmartInto parsea la salida JSON de smartctl y llena los campos S.M.A.R.T.
// de di. Devuelve true si el dispositivo reportó SMART.
func parseSmartInto(di *DiskInfo, out []byte) bool {
	if len(out) == 0 {
		return false
	}
	var s smartJSON
	if err := json.Unmarshal(out, &s); err != nil {
		warn("smartctl", err)
		return false
	}
	if s.SmartStatus == nil && s.NVMeLog == nil && s.ATA == nil {
		return false // el dispositivo no reporta SMART (USB/VM/sin permisos)
	}
	di.SmartAvailable = true

	if s.SmartStatus != nil {
		if s.SmartStatus.Passed {
			di.Health = "PASSED"
		} else {
			di.Health = "FAILED"
		}
	}

	switch {
	case s.NVMeLog != nil:
		di.WrittenBytes = s.NVMeLog.DataUnitsWritten * nvmeDataUnit
		di.ReadBytes = s.NVMeLog.DataUnitsRead * nvmeDataUnit
		di.PowerOnHours = s.NVMeLog.PowerOnHours
		di.PowerCycles = s.NVMeLog.PowerCycles
		di.LifePercentUsed = s.NVMeLog.PercentageUsed
	case s.ATA != nil:
		di.PowerOnHours = s.PowerOnTime.Hours
		di.PowerCycles = s.PowerCycleCount
		lbs := int64(s.LogicalBlockSize)
		if lbs == 0 {
			lbs = 512
		}
		for _, a := range s.ATA.Table {
			switch a.ID {
			case 5: // Reallocated_Sector_Ct
				di.ReallocatedSectors = int(a.Raw.Value)
			case 241: // escrituras totales del host
				di.WrittenBytes = hostBytes(di.Model, a.Name, a.Raw.Value, lbs)
			case 242: // lecturas totales del host
				di.ReadBytes = hostBytes(di.Model, a.Name, a.Raw.Value, lbs)
			}
		}
		di.LifePercentUsed = ataLifeUsed(s.ATA.Table)
		// Fallback: si el top-level vino en 0, leer de los atributos 9 y 12.
		if di.PowerOnHours == 0 || di.PowerCycles == 0 {
			for _, a := range s.ATA.Table {
				if di.PowerOnHours == 0 && a.ID == 9 {
					di.PowerOnHours = int(a.Raw.Value)
				}
				if di.PowerCycles == 0 && a.ID == 12 {
					di.PowerCycles = int(a.Raw.Value)
				}
			}
		}
	}

	evalDiskHealth(di, s)
	return true
}

// chequeoATA describe un atributo S.M.A.R.T. ATA cuyo valor RAW > 0 señala un
// problema. Se listan SOLO atributos fiables entre fabricantes; se excluyen a
// propósito los "ruidosos" (1 Raw_Read_Error_Rate, 7 Seek_Error_Rate) que
// Seagate/WD codifican con raws enormes en discos sanos → falso positivo.
type chequeoATA struct {
	id       int
	severity string
	titulo   string
	detalle  string // qué es + consecuencia
}

var chequeosATA = []chequeoATA{
	{197, "fail", "Sectores pendientes de reasignar",
		"El disco encontró sectores que no puede leer y espera reasignarlos. Consecuencia: pérdida de datos inminente y falla probable; respalda de inmediato."},
	{198, "fail", "Sectores no corregibles",
		"Hay sectores dañados que no se pudieron recuperar. Consecuencia: archivos corruptos; el disco ya no es fiable."},
	{187, "fail", "Errores no corregibles reportados",
		"El disco reportó errores de lectura/escritura que no pudo corregir. Consecuencia: datos corruptos y deterioro en curso."},
	{184, "fail", "Error de extremo a extremo",
		"El disco detectó una inconsistencia en su ruta interna de datos. Consecuencia: los datos pueden guardarse o leerse corruptos."},
	{5, "warning", "Sectores reasignados",
		"El disco ya reemplazó sectores dañados por otros de reserva. Consecuencia: desgaste en marcha; si el número crece, el disco fallará."},
	{196, "warning", "Eventos de reasignación",
		"El disco intentó mover datos desde sectores dañados a los de reserva. Consecuencia: señal de sectores defectuosos en aumento."},
	{199, "warning", "Errores CRC UltraDMA",
		"Fallos de integridad al transferir datos por el bus. Consecuencia: casi siempre es el cable o la conexión USB, no el disco; revisa o cambia el cable/gabinete."},
	{10, "warning", "Reintentos de giro",
		"El motor tardó en alcanzar su velocidad (solo discos mecánicos). Consecuencia: desgaste mecánico; posible falla del motor."},
	{11, "warning", "Reintentos de calibración",
		"El disco tuvo que recalibrar los cabezales (solo discos mecánicos). Consecuencia: posible problema mecánico."},
	{188, "warning", "Comandos expirados",
		"Operaciones que no terminaron a tiempo. Consecuencia: puede indicar problemas de alimentación, cable o del propio disco."},
}

// evalDiskHealth deriva la salud del disco de los atributos SMART (no solo del
// PASSED/FAILED global) y arma la lista de problemas con su consecuencia. Un
// disco con daños ya no es fiable: cualquier señal se marca advertencia o falla.
func evalDiskHealth(di *DiskInfo, s smartJSON) {
	var issues []DiskIssue

	// SMART global: el disco mismo se declara fallando.
	if s.SmartStatus != nil && !s.SmartStatus.Passed {
		issues = append(issues, DiskIssue{"fail", "SMART reporta fallo inminente",
			"El propio disco declara que está fallando (estado SMART = FAILED). Consecuencia: falla probable a corto plazo; respalda y reemplázalo."})
	}

	switch {
	case s.ATA != nil:
		raw := map[int]int64{}
		for _, a := range s.ATA.Table {
			if _, ok := raw[a.ID]; !ok {
				raw[a.ID] = a.Raw.Value
			}
		}
		for _, c := range chequeosATA {
			if v := raw[c.id]; v > 0 {
				issues = append(issues, DiskIssue{c.severity, c.titulo,
					fmt.Sprintf("%s (valor: %d).", c.detalle, v)})
			}
		}
	case s.NVMeLog != nil:
		n := s.NVMeLog
		if n.CriticalWarning != 0 {
			issues = append(issues, DiskIssue{"fail", "Advertencia crítica NVMe",
				"El SSD reporta una condición crítica (temperatura, repuesto agotado o modo solo-lectura). Consecuencia: riesgo alto de pérdida de datos."})
		}
		if n.AvailableSpareThresh > 0 && n.AvailableSpare < n.AvailableSpareThresh {
			issues = append(issues, DiskIssue{"fail", "Bloques de repuesto agotados",
				fmt.Sprintf("Al SSD le quedan %d%% de celdas de reserva (umbral %d%%). Consecuencia: fin de vida; puede pasar a solo-lectura o perder datos.", n.AvailableSpare, n.AvailableSpareThresh)})
		}
		if n.MediaErrors > 0 {
			issues = append(issues, DiskIssue{"warning", "Errores de medio",
				fmt.Sprintf("El SSD registró %d error(es) no corregidos en la memoria NAND. Consecuencia: posibles datos corruptos.", n.MediaErrors)})
		}
	}

	// Vida útil casi agotada (SSD, tanto ATA como NVMe). Usa el % ya calculado.
	if di.LifePercentUsed >= 90 {
		issues = append(issues, DiskIssue{"warning", "Vida útil casi agotada",
			fmt.Sprintf("El disco ha consumido el %d%% de su vida útil estimada. Consecuencia: cercano al fin de vida; planifica su reemplazo.", di.LifePercentUsed)})
	}

	di.Issues = issues
	di.HealthLevel = "good"
	for _, is := range issues {
		if is.Severity == "fail" {
			di.HealthLevel = "fail"
			return
		}
		di.HealthLevel = "warning"
	}
}

// reUnit extrae un múltiplo embebido en el nombre del atributo, p. ej.
// "Host_Writes_32MiB" → (32, MiB), "NAND_Writes_1GiB" → (1, GiB).
var reUnit = regexp.MustCompile(`(\d*)\s*(gib|mib|gb|mb)`)

// modelHostUnit es el RESPALDO del drivedb-add.h embebido (ver drivedbArg): si
// smartctl no pudo cargar el archivo temporal (-B falló) o es muy viejo, este
// override por modelo sigue corrigiendo la unidad de 241/242 en código. Con el
// drivedb-add.h activo, smartctl ya devuelve el nombre "Host_Writes_32MiB" y
// attrToBytes lo resuelve solo, así que esta tabla normalmente no se usa.
// Copiado del drivedb.h: la familia ADATA SU Silicon Motion usa 32 MiB por
// unidad, pero el regex del preset oficial no cubre variantes como "SU800NS38".
var modelHostUnit = []struct {
	re    *regexp.Regexp
	bytes int64
}{
	{regexp.MustCompile(`(?i)ADATA[ _]SU[689]\d\d`), 32 * 1024 * 1024},
}

// hostBytes calcula los bytes de escrituras/lecturas del host: primero un
// override por modelo (firmware que miente bajo un nombre estándar), si no, la
// unidad deducida del nombre del atributo.
func hostBytes(model, name string, raw, lbs int64) int64 {
	for _, o := range modelHostUnit {
		if o.re.MatchString(model) {
			return raw * o.bytes
		}
	}
	return attrToBytes(name, raw, lbs)
}

// attrToBytes convierte el raw de un atributo a bytes decidiendo la unidad por
// el NOMBRE (los controladores reportan en GiB/GB/MiB/sectores bajo nombres
// distintos). Soporta múltiplos embebidos ("..._32MiB"). Ej.: Kingston usa
// "Lifetime_Writes_GiB" (×1024³); la mayoría "Total_LBAs_Written" (×sector).
func attrToBytes(name string, raw, lbs int64) int64 {
	n := strings.ToLower(name)
	if m := reUnit.FindStringSubmatch(n); m != nil {
		mult := int64(1)
		if m[1] != "" {
			if v, err := strconv.ParseInt(m[1], 10, 64); err == nil {
				mult = v
			}
		}
		switch m[2] {
		case "gib":
			return raw * mult * 1024 * 1024 * 1024
		case "gb":
			return raw * mult * 1000 * 1000 * 1000
		case "mib":
			return raw * mult * 1024 * 1024
		case "mb":
			return raw * mult * 1000 * 1000
		}
	}
	if strings.Contains(n, "lba") || strings.Contains(n, "sector") {
		return raw * lbs
	}
	return raw * lbs
}

// ataLifeUsed devuelve el % de vida CONSUMIDA del SSD (-1 si no aplica/HDD).
// Decide por nombre del atributo: los "life left/remaining/wearout" usan el
// valor normalizado (% restante → 100-valor); los "...life_used" dan el % usado
// directo. Wear_Leveling_Count es la aproximación de respaldo.
func ataLifeUsed(table []ataAttr) int {
	for _, a := range table {
		n := strings.ToLower(a.Name)
		switch {
		case strings.Contains(n, "life_used"), strings.Contains(n, "rated_life_used"),
			strings.Contains(n, "lifetime_used"), strings.Contains(n, "perc_rated_life"):
			return clampPct(int(a.Raw.Value))
		case strings.Contains(n, "ssd_life_left"), strings.Contains(n, "life_left"),
			strings.Contains(n, "life_remain"), strings.Contains(n, "lifetime_remain"),
			strings.Contains(n, "remaining_life"), strings.Contains(n, "media_wearout"):
			return clampPct(100 - a.Value)
		}
	}
	for _, a := range table { // respaldo: desgaste por wear leveling
		n := strings.ToLower(a.Name)
		if strings.Contains(n, "wear_leveling") || strings.Contains(n, "wearout") {
			return clampPct(100 - a.Value)
		}
	}
	return -1
}

func clampPct(v int) int {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}

// scanEntry es un dispositivo que reporta `smartctl --scan-open`.
type scanEntry struct {
	Name string `json:"name"` // nombre de dispositivo que SÍ funciona en smartctl
	Type string `json:"type"` // tipo detectado: ata, sat, nvme, scsi, ...
}

// scanOpen pregunta a smartctl qué discos puede abrir y con qué tipo. En Windows
// esto es más fiable que construir "\\.\PHYSICALDRIVEn": smartctl da el nombre y
// el `-d` correctos (cubre NVMe y varios controladores).
func scanOpen() []scanEntry {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	args := append(drivedbArg(), "--scan-open", "--json")
	cmd := exec.CommandContext(ctx, smartctlBin(), args...)
	ocultaVentana(cmd) // Windows: sin ventana de consola negra
	out, _ := cmd.Output()
	var r struct {
		Devices []scanEntry `json:"devices"`
	}
	if json.Unmarshal(out, &r) != nil {
		return nil
	}
	return r.Devices
}

// enrichSmartWindows llena el S.M.A.R.T. en Windows: en vez de adivinar el
// nombre del dispositivo (ghw da "\\.\PHYSICALDRIVEn", que smartctl no siempre
// acepta), pregunta con `--scan-open` y empareja cada resultado con el disco de
// ghw por número de serie/modelo. Deja un log de diagnóstico junto al ejecutable
// (smart-debug.log) por si algún equipo sigue sin reportar SMART.
func enrichSmartWindows(disks []DiskInfo) {
	var log strings.Builder
	devs := scanOpen()
	fmt.Fprintf(&log, "smartctl bin: %s\n", smartctlBin())
	fmt.Fprintf(&log, "scan-open: %d dispositivo(s)\n", len(devs))

	if len(devs) == 0 {
		// Respaldo: intentar con los nombres nativos de ghw.
		for i := range disks {
			ok := parseSmartInto(&disks[i], runSmartctl(disks[i].Name, ""))
			fmt.Fprintf(&log, "respaldo %s: smart=%v\n", disks[i].Name, ok)
		}
	} else {
		for _, d := range devs {
			out := runSmartctl(d.Name, d.Type)
			var meta smartJSON
			json.Unmarshal(out, &meta)
			idx := matchDisk(disks, meta.SerialNumber, meta.ModelName)
			ok := false
			if idx >= 0 {
				ok = parseSmartInto(&disks[idx], out)
			}
			fmt.Fprintf(&log, "dev %s (-d %s): serial=%q modelo=%q → disco #%d smart=%v\n",
				d.Name, d.Type, meta.SerialNumber, meta.ModelName, idx, ok)
		}
	}

	// Pasada USB/UASP: los discos que siguen SIN SMART suelen ser externos en
	// gabinete (--scan-open no los cubre o los abre con el tipo equivocado). Se
	// reintenta por su ruta física con los tipos de puente USB (como CrystalDiskInfo).
	probeSmartUSB(disks, &log)

	writeSmartDebug(log.String())
}

// tiposSMARTWindowsUSB son los `-d` que smartctl usa para hablar ATA a través de
// un puente USB/UASP (gabinetes externos). Se prueban en orden hasta que uno
// responda: "sat" cubre la mayoría de gabinetes UASP modernos (p. ej. ADATA
// ED600); los usb* son puentes específicos (JMicron, ASMedia, Prolific…).
var tiposSMARTWindowsUSB = []string{"sat", "usbjmicron", "usbasm1051", "usbprolific", "usbsunplus"}

// probeSmartUSB reintenta el SMART de los discos que quedaron sin él, hablando
// directo con su ruta física \\.\PHYSICALDRIVEn (no hace falta emparejar por
// serie: se sondea ESE disco). Un puente USB oculta el modelo/serie reales —ghw
// solo ve el gabinete ("ADATA ED600 SCSI Disk Device")—, así que al leer el SMART
// también se corrigen con el modelo/serie verdaderos del disco.
func probeSmartUSB(disks []DiskInfo, log *strings.Builder) {
	for i := range disks {
		if disks[i].SmartAvailable {
			continue
		}
		for _, dt := range tiposSMARTWindowsUSB {
			out := runSmartctl(disks[i].Name, dt)
			if !parseSmartInto(&disks[i], out) {
				continue
			}
			var meta smartJSON
			if json.Unmarshal(out, &meta) == nil {
				if m := strings.TrimSpace(meta.ModelName); m != "" {
					disks[i].Model = m
				}
				if s := strings.TrimSpace(meta.SerialNumber); s != "" {
					disks[i].Serial = s
				}
			}
			fmt.Fprintf(log, "usb %s (-d %s): SMART OK modelo=%q\n", disks[i].Name, dt, disks[i].Model)
			break
		}
	}
}

// matchDisk empareja un resultado de smartctl con un disco de ghw: primero por
// número de serie (normalizado), luego —si hay un solo disco— directo, y por
// último por modelo. Devuelve el índice o -1.
func matchDisk(disks []DiskInfo, serial, model string) int {
	if ns := normSerial(serial); ns != "" {
		for i := range disks {
			if normSerial(disks[i].Serial) == ns {
				return i
			}
		}
	}
	if len(disks) == 1 {
		return 0
	}
	if m := strings.TrimSpace(model); m != "" {
		for i := range disks {
			if strings.EqualFold(strings.TrimSpace(disks[i].Model), m) {
				return i
			}
		}
	}
	return -1
}

func normSerial(s string) string {
	return strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(s), " ", ""))
}

// writeSmartDebug escribe el log de diagnóstico junto al ejecutable del backend
// (best-effort; corre elevado en Windows, así que puede escribir en Program Files).
func writeSmartDebug(content string) {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(filepath.Dir(exe), "smart-debug.log"), []byte(content), 0o644)
}
