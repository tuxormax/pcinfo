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
// En macOS pasa lo mismo que en Windows por otro motivo: una app abierta desde el
// Finder recibe un PATH mínimo que NO incluye /opt/homebrew/bin, así que el
// smartctl instalado con Homebrew no se encontraría (ver resolveSmartctlDarwin).
func resolveSmartctl() {
	smartctlOnce.Do(func() {
		if runtime.GOOS == "darwin" {
			resolveSmartctlDarwin()
			return
		}
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
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Value  int    `json:"value"`  // valor normalizado (0-100), no el raw
	Thresh int    `json:"thresh"` // umbral de falla que define el propio disco (0 = no define uno)
	Raw    struct {
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

// Esperas de smartctl. La consulta normal conserva 8 s (un disco tras ciertos
// controladores tarda en contestar). Los REINTENTOS por puente USB llevan menos
// (4 s): ahí se prueban varios tipos a ver cuál responde y el equivocado falla
// enseguida — sin recortarlo, un lector de tarjetas vacío se comía 5×8 s él
// solo y /hardware se pasaba de los 30 s que espera la GUI. presupuestoUSB es
// el tope de TODA la pasada de reintentos, pase lo que pase.
const (
	timeoutSmart    = 8 * time.Second
	timeoutSmartUSB = 4 * time.Second
	presupuestoUSB  = 20 * time.Second
)

// runSmartctl ejecuta `smartctl --json -a <device>` (con `-d <type>` si se
// indica) y devuelve stdout. Timeout duro: en algunos discos (USB, NVMe/SATA
// tras ciertos controladores) smartctl puede tardar o colgarse; sin límite,
// /hardware excedería el timeout de la GUI. smartctl sale con código ≠0 aunque
// el JSON sea válido (flags), por eso ignoramos el error del proceso.
func runSmartctl(device, dtype string, espera time.Duration) []byte {
	ctx, cancel := context.WithTimeout(context.Background(), espera)
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
	parseSmartInto(di, runSmartctl(di.Name, "", timeoutSmart))
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
	// 199 (Errores CRC UltraDMA) NO va aquí: un error aislado de cable/USB es
	// normal y no dice nada del disco. Se evalúa aparte, contra el umbral que
	// el propio disco reporta (mismo criterio que CrystalDiskInfo) — ver
	// idCRCUltraDMA más abajo.
	{10, "warning", "Reintentos de giro",
		"El motor tardó en alcanzar su velocidad (solo discos mecánicos). Consecuencia: desgaste mecánico; posible falla del motor."},
	{11, "warning", "Reintentos de calibración",
		"El disco tuvo que recalibrar los cabezales (solo discos mecánicos). Consecuencia: posible problema mecánico."},
	{188, "warning", "Comandos expirados",
		"Operaciones que no terminaron a tiempo. Consecuencia: puede indicar problemas de alimentación, cable o del propio disco."},
}

// idCRCUltraDMA es el atributo 199 (UDMA_CRC_Error_Count): errores de
// integridad al transferir datos por el bus (cable, puerto, gabinete USB).
const idCRCUltraDMA = 199

// chequeoCRCUltraDMA evalúa el atributo 199 con el criterio real de SMART:
// el disco falla cuando su valor normalizado cae al umbral (o por debajo) que
// EL PROPIO DISCO define — no con que el contador de errores sea mayor a
// cero. Un tropiezo aislado del cable/USB es normal y no baja el normalizado
// ni de cerca; por eso CrystalDiskInfo lo deja en "Bueno" con el mismo disco
// que antes mostrábamos "CON DESGASTE". Si el disco no define umbral
// (Thresh == 0, común en varios Toshiba/WD), el atributo es solo informativo
// y nunca dispara aviso, igual que en cualquier lector SMART estándar.
func chequeoCRCUltraDMA(tabla []ataAttr) (DiskIssue, bool) {
	for _, a := range tabla {
		if a.ID != idCRCUltraDMA {
			continue
		}
		if a.Thresh <= 0 || a.Value > a.Thresh {
			return DiskIssue{}, false
		}
		return DiskIssue{"warning", "Errores CRC UltraDMA",
			fmt.Sprintf("Fallos de integridad al transferir datos por el bus. Consecuencia: casi siempre es el cable o la conexión USB, no el disco; revisa o cambia el cable/gabinete (valor: %d).", a.Raw.Value)}, true
	}
	return DiskIssue{}, false
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
		if is, ok := chequeoCRCUltraDMA(s.ATA.Table); ok {
			issues = append(issues, is)
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
	ctx, cancel := context.WithTimeout(context.Background(), timeoutSmart)
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
func enrichSmartWindows(disks []DiskInfo, forzarUSB string) {
	var log strings.Builder
	devs := scanOpen()
	fmt.Fprintf(&log, "smartctl bin: %s\n", smartctlBin())
	fmt.Fprintf(&log, "scan-open: %d dispositivo(s)\n", len(devs))

	if len(devs) == 0 {
		// Respaldo: intentar con los nombres nativos de ghw.
		salidas := smartctlParalelo(len(disks), func(i int) []byte {
			return runSmartctl(disks[i].Name, "", timeoutSmart)
		})
		for i := range disks {
			ok := parseSmartInto(&disks[i], salidas[i])
			fmt.Fprintf(&log, "respaldo %s: smart=%v\n", disks[i].Name, ok)
		}
	} else {
		salidas := smartctlParalelo(len(devs), func(i int) []byte {
			return runSmartctl(devs[i].Name, devs[i].Type, timeoutSmart)
		})
		for i, d := range devs {
			out := salidas[i]
			var meta smartJSON
			json.Unmarshal(out, &meta)
			idx := matchDisk(disks, meta.SerialNumber, meta.ModelName)
			ok := false
			if idx >= 0 {
				ok = parseSmartInto(&disks[idx], out)
				if ok {
					aplicaModeloSerieReal(&disks[idx], meta)
				}
			}
			fmt.Fprintf(&log, "dev %s (-d %s): serial=%q modelo=%q → disco #%d smart=%v\n",
				d.Name, d.Type, meta.SerialNumber, meta.ModelName, idx, ok)
		}
	}

	// Pasada USB/UASP: los discos que siguen SIN SMART suelen ser externos en
	// gabinete (--scan-open no los cubre o los abre con el tipo equivocado). Se
	// reintenta por su ruta física con los tipos de puente USB (como CrystalDiskInfo).
	probeSmartUSB(disks, &log, forzarUSB)

	writeSmartDebug(log.String())
}

// smartctlParalelo lanza n consultas de smartctl A LA VEZ y devuelve sus salidas
// en el mismo orden. Antes se hacían una tras otra: con 8 s de tope por consulta,
// tres discos lentos ya sumaban 24 s y la GUI cortaba la espera. Solo se
// paraleliza la EJECUCIÓN (lo lento); el parseo y el emparejamiento con los
// discos quedan fuera, en serie, para no escribir el arreglo desde varias
// goroutines a la vez.
func smartctlParalelo(n int, corre func(i int) []byte) [][]byte {
	salidas := make([][]byte, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			salidas[i] = corre(i)
		}(i)
	}
	wg.Wait()
	return salidas
}

// tiposSMARTWindowsUSB son los `-d` que smartctl usa para hablar ATA a través de
// un puente USB/UASP (gabinetes externos). Se prueban en orden hasta que uno
// responda: "sat" cubre la mayoría de gabinetes UASP modernos (p. ej. ADATA
// ED600); los usb* son puentes específicos (JMicron, ASMedia, Prolific…).
var tiposSMARTWindowsUSB = []string{"sat", "usbjmicron", "usbasm1051", "usbprolific", "usbsunplus"}

// aplicaModeloSerieReal sobreescribe el modelo/serie del disco con los que
// smartctl leyó de verdad. Hace falta cuando el disco cuelga de un puente
// (USB, RAID) que al sistema operativo le da un nombre genérico del propio
// puente —p. ej. "JMicron Tech SCSI Disk Device"— en vez del disco real.
func aplicaModeloSerieReal(d *DiskInfo, meta smartJSON) {
	if m := strings.TrimSpace(meta.ModelName); m != "" {
		d.Model = m
	}
	if s := strings.TrimSpace(meta.SerialNumber); s != "" {
		d.Serial = s
	}
}

// probeSmartUSB reintenta el SMART de los discos que quedaron sin él, hablando
// directo con su ruta física \\.\PHYSICALDRIVEn (no hace falta emparejar por
// serie: se sondea ESE disco). Un puente USB oculta el modelo/serie reales —ghw
// solo ve el gabinete ("ADATA ED600 SCSI Disk Device")—, así que al leer el SMART
// también se corrigen con el modelo/serie verdaderos del disco.
func probeSmartUSB(disks []DiskInfo, log *strings.Builder, forzarUSB string) {
	limite := time.Now().Add(presupuestoUSB)
	var mu sync.Mutex // el log lo escriben varias goroutines
	var wg sync.WaitGroup
	for i := range disks {
		forzado := forzarUSB != "" && strings.EqualFold(disks[i].Name, forzarUSB)
		if disks[i].SmartAvailable || (!puedeSerPuenteUSB(disks[i]) && !forzado) {
			continue
		}
		// Un sondeo pedido a mano se toma su tiempo (el usuario lo está
		// esperando a propósito); el automático corre con la espera corta.
		espera := timeoutSmartUSB
		if forzado {
			espera = timeoutSmart
		}
		wg.Add(1)
		go func(d *DiskInfo, espera time.Duration, forzado bool) { // cada goroutine toca SOLO su disco
			defer wg.Done()
			var linea strings.Builder
			for _, dt := range tiposSMARTWindowsUSB {
				if !forzado && time.Now().After(limite) {
					fmt.Fprintf(&linea, "usb %s: presupuesto agotado (%s), no se probaron más tipos\n",
						d.Name, presupuestoUSB)
					break
				}
				out := runSmartctl(d.Name, dt, espera)
				if !parseSmartInto(d, out) {
					continue
				}
				var meta smartJSON
				if json.Unmarshal(out, &meta) == nil {
					aplicaModeloSerieReal(d, meta)
				}
				fmt.Fprintf(&linea, "usb %s (-d %s): SMART OK modelo=%q\n", d.Name, dt, d.Model)
				break
			}
			if linea.Len() > 0 {
				mu.Lock()
				log.WriteString(linea.String())
				mu.Unlock()
			}
		}(&disks[i], espera, forzado)
	}
	wg.Wait()
}

// puedeSerPuenteUSB descarta los discos donde sondear tipos de puente USB es
// tiempo tirado:
//   - un NVMe interno cuelga del PCIe, nunca de un gabinete USB;
//   - una MEMORIA USB o una tarjeta SD (medio removible) no reporta S.M.A.R.T. y
//     encima tarda en contestar que no — era lo que hacía esperar a la app.
//
// Un SSD/NVMe dentro de un gabinete externo NO cae aquí: Windows lo presenta
// como disco fijo/externo, no como medio removible, así que se le sigue leyendo.
// Para el gabinete que se declare removible está el sondeo forzado desde la GUI.
func puedeSerPuenteUSB(d DiskInfo) bool {
	if d.Removable {
		return false
	}
	bus := strings.ToLower(d.Bus)
	tipo := strings.ToLower(d.Type)
	return !strings.Contains(bus, "nvme") && !strings.Contains(tipo, "nvme")
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
//
// ⛔ En macOS NO puede ir junto al ejecutable: ese archivo vive DENTRO del .app
// firmado (Contents/MacOS/), y escribir ahí en cada arranque invalida la firma
// —`codesign --verify --deep` empieza a fallar con "a sealed resource is
// missing or invalid" después del primer uso, aunque el .app siga abriendo
// igual. Se comprobó al armar el universal el 12-Sep-2026: el .app recién
// firmado verificaba limpio, y dejaba de hacerlo en cuanto se abría una vez.
// En macOS el log va a la carpeta estándar de logs de la app, fuera del bundle.
func writeSmartDebug(content string) {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	ruta := filepath.Join(filepath.Dir(exe), "smart-debug.log")
	if runtime.GOOS == "darwin" {
		if home, err := os.UserHomeDir(); err == nil {
			dir := filepath.Join(home, "Library", "Logs", "PCInfo")
			if os.MkdirAll(dir, 0o755) == nil {
				ruta = filepath.Join(dir, "smart-debug.log")
			}
		}
	}
	_ = os.WriteFile(ruta, []byte(content), 0o644)
}
