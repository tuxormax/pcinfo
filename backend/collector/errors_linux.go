//go:build linux

package collector

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Historial de errores en Linux. Equivalente al script de Windows (BSOD +
// registro de eventos), aquí con las fuentes propias del sistema:
//
//	journald  -p err   → errores del sistema y del kernel (Oops, OOM, E/S…)
//	journald  -k -p warn → avisos de HARDWARE que no llegan a "err" (MCE, ATA…)
//	journald  -t systemd-coredump → programas que se cayeron (equivale a los .dmp)
//	journalctl --list-boots → arranques sin apagado limpio (= "apagado inesperado")
//	systemctl --failed → servicios que no arrancaron o murieron
//	/var/crash, /var/lib/systemd/coredump → volcados presentes en el disco
//
// Cada mensaje crudo pasa por el catálogo `reglasLog`, que lo traduce a
// "qué pasó / por qué / cómo se resuelve" en español, igual que el catálogo de
// STOP codes del lado de Windows. Sin journald (systemd ausente) se cae a
// /var/log/{syslog,kern.log,messages}.

// Tiempo máximo por comando: los registros pueden ser grandes y no queremos
// colgar el endpoint /errores.
const timeoutLog = 20 * time.Second

func collectErrors() ErrorsReport {
	rep := ErrorsReport{
		OS:       runtime.GOOS,
		Elevated: isElevated(),
		ScanDays: diasAnalisis,
		Source:   "journald (registros del sistema y del kernel)",
		Items:    []SystemError{},
		Dumps:    []DumpFile{},
	}
	desde := time.Now().AddDate(0, 0, -diasAnalisis)

	if tieneComando("journalctl") {
		// Las dos pasadas se juntan y se agrupan UNA sola vez: si se agruparan por
		// separado, el mismo problema saldría dos veces en la lista (los mensajes
		// de prioridad 3 del kernel aparecen en ambas consultas).
		todas := []entradaLog{}
		// 1) Errores del sistema completo (prioridad err o peor).
		if ent, err := leeJournal(desde, "-p", "3", "-n", "4000"); err != nil {
			warn("journalctl err", err)
		} else {
			todas = append(todas, ent...)
			rep.Available = true
		}
		// 2) Avisos SOLO del kernel: los errores de hardware (MCE corregibles,
		// reintentos ATA, resets de GPU) se registran como "warning" y se
		// perderían con -p 3. Aquí solo se conserva lo que casa con una regla.
		if ent, err := leeJournal(desde, "-k", "-p", "4", "-n", "3000"); err != nil {
			warn("journalctl kernel", err)
		} else {
			for i := range ent {
				ent[i].soloRegla = true
			}
			todas = append(todas, ent...)
			rep.Available = true
		}
		rep.Items = append(rep.Items, agrupaEntradas(sinRepetidas(todas))...)
		// 3) Programas que se cayeron (systemd-coredump) = los .dmp de Windows.
		if ent, err := leeJournal(desde, "-t", "systemd-coredump", "-p", "6", "-n", "200"); err == nil {
			rep.Items = append(rep.Items, agrupaCoredumps(ent)...)
		}
		rep.Items = append(rep.Items, arranquesSucios()...)
		if !rep.Available {
			rep.Reason = razonSinJournal(rep.Elevated)
		}
	} else {
		// Sin systemd: se leen los archivos de texto clásicos.
		rep.Source = "/var/log (syslog, kern.log, messages)"
		ent, err := leeLogsTexto(desde)
		if err != nil {
			rep.Reason = "No se pudieron leer los registros del sistema: " + err.Error() +
				" Ejecuta PCInfo como root para acceder a /var/log."
		} else {
			rep.Available = true
			rep.Items = append(rep.Items, agrupaEntradas(ent)...)
		}
	}

	rep.Items = append(rep.Items, unidadesFallidas()...)
	rep.Dumps = volcadosLinux()
	return rep
}

func razonSinJournal(elevado bool) string {
	if elevado {
		return "No se pudo leer el diario del sistema (journald). ¿Está systemd-journald en ejecución?"
	}
	return "No se pudo leer el diario del sistema. PCInfo necesita ejecutarse como root " +
		"(o que el usuario esté en el grupo 'adm'/'systemd-journal') para ver los errores del sistema."
}

func tieneComando(nombre string) bool {
	_, err := exec.LookPath(nombre)
	return err == nil
}

// ---------------------------------------------------------------------------
// Lectura de journald
// ---------------------------------------------------------------------------

// entradaLog es una línea de registro ya normalizada, venga de journald o de un
// archivo de texto.
type entradaLog struct {
	when      time.Time
	msg       string
	ident     string // SYSLOG_IDENTIFIER o proceso
	unit      string // unidad systemd (si aplica)
	prio      int    // 0..7 (syslog); 3 = err
	soloRegla bool   // descartar si no casa con el catálogo (barrido de avisos)
	extra     map[string]string
}

// texto es la línea completa para clasificar: journald guarda el emisor aparte
// del mensaje ("bluetoothd" + "Failed to set mode"), pero las reglas del
// catálogo se escribieron sobre la línea completa, como se ve en el log.
func (e entradaLog) texto() string {
	if e.ident == "" {
		return e.msg
	}
	return e.ident + ": " + e.msg
}

// sinRepetidas quita las entradas idénticas (mismo instante y mismo texto) que
// aparecen en más de una consulta a journald.
func sinRepetidas(ents []entradaLog) []entradaLog {
	vistas := make(map[string]bool, len(ents))
	out := make([]entradaLog, 0, len(ents))
	for _, e := range ents {
		k := strconv.FormatInt(e.when.UnixMicro(), 10) + "|" + e.msg
		if vistas[k] {
			continue
		}
		vistas[k] = true
		out = append(out, e)
	}
	return out
}

// leeJournal ejecuta journalctl en JSON y devuelve las entradas del periodo.
func leeJournal(desde time.Time, args ...string) ([]entradaLog, error) {
	base := []string{
		"--no-pager", "-o", "json",
		"--since", desde.Format("2006-01-02 15:04:05"),
	}
	out, err := corre("journalctl", append(base, args...)...)
	if err != nil {
		return nil, err
	}
	return parseaJournalJSON(out), nil
}

func parseaJournalJSON(out string) []entradaLog {
	ents := []entradaLog{}
	sc := bufio.NewScanner(strings.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		linea := strings.TrimSpace(sc.Text())
		if linea == "" || !strings.HasPrefix(linea, "{") {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(linea), &m); err != nil {
			continue
		}
		msg := campoJournal(m, "MESSAGE")
		if strings.TrimSpace(msg) == "" {
			continue
		}
		e := entradaLog{
			msg:   msg,
			ident: campoJournal(m, "SYSLOG_IDENTIFIER"),
			unit:  campoJournal(m, "_SYSTEMD_UNIT"),
			prio:  3,
			extra: map[string]string{
				"exe":  campoJournal(m, "COREDUMP_EXE"),
				"sig":  campoJournal(m, "COREDUMP_SIGNAL_NAME"),
				"comm": campoJournal(m, "COREDUMP_COMM"),
			},
		}
		if e.ident == "" {
			e.ident = campoJournal(m, "_COMM")
		}
		if p, err := strconv.Atoi(campoJournal(m, "PRIORITY")); err == nil {
			e.prio = p
		}
		if us, err := strconv.ParseInt(campoJournal(m, "__REALTIME_TIMESTAMP"), 10, 64); err == nil {
			e.when = time.UnixMicro(us)
		}
		ents = append(ents, e)
	}
	return ents
}

// campoJournal devuelve un campo del JSON de journald como texto. journald puede
// entregar un campo como cadena, como lista de bytes (mensajes binarios) o como
// lista de valores repetidos; aquí se normaliza todo a texto.
func campoJournal(m map[string]any, clave string) string {
	v, ok := m[clave]
	if !ok {
		return ""
	}
	switch t := v.(type) {
	case string:
		return t
	case []any:
		bytes := make([]byte, 0, len(t))
		partes := []string{}
		for _, it := range t {
			switch x := it.(type) {
			case float64:
				bytes = append(bytes, byte(int(x)))
			case string:
				partes = append(partes, x)
			}
		}
		if len(partes) > 0 {
			return strings.Join(partes, " ")
		}
		return string(bytes)
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Catálogo: mensaje del kernel/sistema → causa y solución en español
// ---------------------------------------------------------------------------

type reglaLog struct {
	id       string
	re       *regexp.Regexp
	kind     string
	severity string
	title    string
	cause    string
	fix      string
}

// reglasLog se evalúa EN ORDEN: gana la primera que case. Lo más grave y más
// específico va arriba. Es el equivalente Linux del catálogo de STOP codes.
var reglasLog = []reglaLog{
	{
		id: "panic", re: regexp.MustCompile(`(?i)Kernel panic|kernel BUG at|BUG: unable to handle|Oops:|general protection fault|Fatal exception`),
		kind: KindBSOD, severity: SevCritico,
		title: "Fallo grave del kernel (equivalente al pantallazo azul)",
		cause: "El núcleo de Linux se topó con un estado imposible y detuvo el sistema. Casi siempre lo provoca un MÓDULO/driver defectuoso (gráfica, red, virtualización) o memoria RAM dañada.",
		fix:   "Anota el módulo que aparece en el mensaje (línea 'Modules linked in' o el nombre tras el '?'): actualiza o quita ese driver. Si no hay módulo de terceros, prueba la RAM con memtest86+ y arranca con un kernel anterior desde GRUB.",
	},
	{
		id: "lockup", re: regexp.MustCompile(`(?i)watchdog: BUG: soft lockup|hard LOCKUP|rcu_sched detected stalls|blocked for more than \d+ seconds`),
		kind: KindBSOD, severity: SevCritico,
		title: "El sistema se congeló (bloqueo de CPU o tarea colgada)",
		cause: "Una tarea del kernel monopolizó la CPU o quedó esperando indefinidamente. Suele ser un driver, un disco que no responde o un sistema de archivos de red caído.",
		fix:   "Mira qué proceso/driver menciona el mensaje. Si es de disco, revisa la salud del disco en la pestaña Hardware; si es de red (NFS/CIFS), revisa el servidor. Actualiza el kernel y los drivers.",
	},
	{
		id: "mce", re: regexp.MustCompile(`(?i)\bmce:|Machine check|Hardware Error|MCE .*CPU|EDAC.*(UE|CE|error)`),
		kind: KindHardware, severity: SevCritico,
		title: "Error de HARDWARE reportado por la CPU (MCE)",
		cause: "El propio procesador detectó un error físico: memoria RAM defectuosa, sobrecalentamiento, voltaje/fuente inestable o CPU dañada. NO es un problema de software.",
		fix:   "Prueba la RAM con memtest86+ (varias pasadas), limpia el disipador y revisa temperaturas y la fuente de poder. Si hay overclock o XMP/EXPO activado, desactívalo y vuelve a probar.",
	},
	{
		id: "oom", re: regexp.MustCompile(`(?i)Out of memory: Kill|oom-kill|Killed process \d+`),
		kind: KindMemoria, severity: SevError,
		title: "El sistema se quedó sin memoria y mató un programa",
		cause: "La RAM (y el swap) se agotaron, así que el kernel eligió un proceso y lo cerró para no colgar el equipo.",
		fix:   "Cierra programas que consuman mucha memoria, amplía la RAM o aumenta el archivo/partición de swap. Si un mismo programa lo provoca siempre, es una fuga de memoria de ese programa.",
	},
	{
		id: "termico", re: regexp.MustCompile(`(?i)temperature above threshold|thermal.*(critical|shutdown)|Core temperature|critical temperature reached`),
		kind: KindHardware, severity: SevCritico,
		title: "Temperatura crítica: el equipo se está sobrecalentando",
		cause: "La CPU superó su límite térmico y bajó su frecuencia (o el equipo se apagó) para no dañarse. Ventilador sucio, pasta térmica seca o poca ventilación.",
		fix:   "Limpia ventiladores y disipadores, cambia la pasta térmica y verifica que todos los ventiladores giren. En portátiles, no lo uses sobre superficies blandas.",
	},
	{
		id: "medio", re: regexp.MustCompile(`(?i)critical medium error|Medium Error|unrecovered read error|Unrecovered read error|bad block|failed to read sector`),
		kind: KindDisco, severity: SevCritico,
		title: "Sectores dañados en el disco",
		cause: "El disco no pudo leer datos de una zona física: hay sectores dañados. Es un disco muriendo.",
		fix:   "RESPALDA YA tus datos. Revisa el S.M.A.R.T. del disco en la pestaña Hardware y reemplaza la unidad; los sectores dañados siempre van en aumento.",
	},
	{
		id: "io", re: regexp.MustCompile(`(?i)I/O error|blk_update_request|Buffer I/O error|end_request: .*error|print_req_error`),
		kind: KindDisco, severity: SevError,
		title: "Errores de lectura/escritura en el disco",
		cause: "El sistema no pudo leer o escribir en la unidad. Puede ser el disco fallando, un cable SATA/USB flojo o un puerto con problemas.",
		fix:   "Cambia el cable SATA/USB y prueba otro puerto. Revisa el S.M.A.R.T. del disco en la pestaña Hardware; si tiene sectores reasignados o pendientes, respalda y reemplázalo.",
	},
	{
		id: "ata", re: regexp.MustCompile(`(?i)ata\d+(\.\d+)?: (failed command|exception Emask|SError|hard resetting link)|link is slow to respond|COMRESET failed`),
		kind: KindDisco, severity: SevError,
		title: "La controladora reinició el enlace con un disco (SATA)",
		cause: "El disco dejó de responder y el kernel tuvo que reiniciar el enlace. Es típico de cable SATA en mal estado, alimentación insuficiente o disco fallando.",
		fix:   "Cambia el cable SATA y el conector de corriente, prueba otro puerto de la placa y revisa la salud S.M.A.R.T. del disco.",
	},
	{
		id: "fs", re: regexp.MustCompile(`(?i)EXT4-fs error|EXT4-fs .*corrupt|XFS \(.*\): (Corruption|metadata I/O error)|Btrfs.*(checksum|corrupt)|NTFS-fs error|Remounting filesystem read-only`),
		kind: KindDisco, severity: SevCritico,
		title: "Sistema de archivos dañado",
		cause: "Se detectaron estructuras corruptas en la partición. Suele venir de apagones/apagados forzados o de un disco con sectores dañados.",
		fix:   "Arranca desde un USB en vivo y corre 'fsck' sobre la partición afectada (nunca montada). Después revisa el S.M.A.R.T. del disco: si está dañado, reemplázalo.",
	},
	{
		id: "gpu", re: regexp.MustCompile(`(?i)NVRM: Xid|amdgpu.*(ring .*timeout|GPU reset|VM_L2|GPU fault)|i915.*(GPU HANG|Resetting)|drm.*(flip_done timed out|atomic update failed)|nouveau.*fifo`),
		kind: KindGrafica, severity: SevError,
		title: "El driver de video falló o tuvo que reiniciar la GPU",
		cause: "La tarjeta gráfica dejó de responder y el driver la reinició. Causas típicas: driver defectuoso, sobrecalentamiento de la GPU o alimentación insuficiente.",
		fix:   "Actualiza (o revierte) el driver de video, limpia el polvo de la tarjeta y verifica la fuente de poder. En NVIDIA, el número 'Xid' identifica el fallo exacto.",
	},
	{
		id: "pcie", re: regexp.MustCompile(`(?i)pcieport.*(AER|error)|PCIe Bus Error|Bad TLP|Bad DLLP`),
		kind: KindHardware, severity: SevAviso,
		title: "Errores en el bus PCI Express",
		cause: "Se detectaron errores de transmisión entre la placa y una tarjeta PCIe (gráfica, NVMe, red). Puede ser contacto sucio, tarjeta mal asentada o incompatibilidad de firmware.",
		fix:   "Reasienta la tarjeta y límpiale los contactos, actualiza la BIOS y, si persiste, prueba la tarjeta en otra ranura.",
	},
	{
		id: "firmware", re: regexp.MustCompile(`(?i)Direct firmware load for .* failed|firmware: failed to load|Falling back to sysfs fallback`),
		kind: KindSistema, severity: SevAviso,
		title: "Falta un archivo de firmware para un dispositivo",
		cause: "El kernel encontró un dispositivo (WiFi, gráfica, bluetooth) pero no el firmware que necesita, así que el dispositivo puede no funcionar del todo.",
		fix:   "Instala el paquete de firmware correspondiente (linux-firmware, firmware-realtek, etc.) y reinicia.",
	},
	{
		id: "usb", re: regexp.MustCompile(`(?i)usb .*(device descriptor read|device not accepting address|unable to enumerate)|reset (high|full|SuperSpeed) speed USB device`),
		kind: KindSistema, severity: SevAviso,
		title: "Un dispositivo USB se desconectó o no se pudo inicializar",
		cause: "El puerto o el cable USB pierden contacto, o el dispositivo pide más corriente de la que da el puerto (típico en discos externos).",
		fix:   "Cambia el cable, usa un puerto trasero (conectado directo a la placa) y evita los concentradores sin alimentación propia.",
	},
	{
		id: "segfault", re: regexp.MustCompile(`(?i)segfault at|general protection ip:|traps: .*trap|SIGSEGV|SIGABRT`),
		kind: KindApp, severity: SevError,
		title: "Un programa se cerró de golpe (violación de segmento)",
		cause: "La aplicación intentó usar memoria que no le pertenece y el sistema la terminó. Suele ser un error del propio programa o una biblioteca incompatible.",
		fix:   "Actualiza el programa y el sistema. Si siempre falla el mismo, reinstálalo; si fallan varios distintos, prueba la RAM con memtest86+.",
	},
	{
		id: "servicio", re: regexp.MustCompile(`(?i)Failed to start|Failed with result|entered failed state|start request repeated too quickly`),
		kind: KindServicio, severity: SevError,
		title: "Un servicio del sistema no pudo arrancar",
		cause: "Una unidad de systemd terminó con error: configuración inválida, dependencia ausente o el programa se cayó al iniciar.",
		fix:   "Consulta el detalle con 'systemctl status <unidad>' y 'journalctl -u <unidad> -b'. Corrige la configuración o reinstala el paquete del servicio.",
	},
	{
		id: "red", re: regexp.MustCompile(`(?i)(NETDEV WATCHDOG|transmit queue \d+ timed out|Link is Down|carrier lost)`),
		kind: KindSistema, severity: SevAviso,
		title: "La red se cayó o el adaptador dejó de responder",
		cause: "El driver de red reinició el adaptador porque dejó de transmitir, o el enlace físico se perdió (cable/switch/WiFi).",
		fix:   "Revisa el cable y el puerto del switch; en WiFi, la distancia y el canal. Actualiza el driver o el firmware del adaptador.",
	},

	// --- Ruido conocido -------------------------------------------------------
	// Mensajes que el sistema registra como "error" pero que NO afectan al uso
	// del equipo. Van al final: cualquier regla real de arriba gana. Se muestran
	// como aviso y diciendo claramente que no hay nada que hacer, en vez de
	// dejar que el catálogo genérico los pinte como errores alarmantes.
	{
		id: "acpi", re: regexp.MustCompile(`(?i)ACPI (BIOS )?Error|ACPI Error|ACPI Warning|Firmware Bug`),
		kind: KindSistema, severity: SevAviso,
		title: "Aviso de la BIOS: tablas ACPI con defectos",
		cause: "El firmware de la placa declara mal alguna tabla ACPI y el kernel lo reporta al arrancar. Linux aplica su propio remedio y el equipo funciona con normalidad.",
		fix:   "No requiere acción. Si el fabricante publica una BIOS más nueva, actualizarla suele quitar estos avisos.",
	},
	{
		id: "bluetooth", re: regexp.MustCompile(`(?i)sap-server|sap_server_register|bluetoothd.*Failed to set mode`),
		kind: KindSistema, severity: SevAviso,
		title: "Bluetooth: un perfil opcional no se pudo activar",
		cause: "El servicio de Bluetooth intentó cargar un perfil que el adaptador no soporta (normalmente SAP, de telefonía). Es un mensaje habitual y no afecta al uso normal del Bluetooth.",
		fix:   "No requiere acción. Si molesta, se puede desactivar el perfil en la configuración de bluetoothd.",
	},
	{
		id: "escritorio", re: regexp.MustCompile(`(?i)(gkr-pam|assertion '.*' failed|GLib-GObject|couldn't connect to accessibility bus|unable to locate daemon control file)`),
		kind: KindSistema, severity: SevAviso,
		title: "Mensaje interno del entorno gráfico",
		cause: "Un componente del escritorio (sesión, llavero, accesibilidad) registró un mensaje de depuración. No indica una falla real del sistema.",
		fix:   "No requiere acción salvo que notes un fallo concreto al iniciar sesión.",
	},
}

// Patrones para identificar A QUIÉN le pasó el error (unidad, programa, disco).
// Con esto el título deja de ser genérico ("un servicio falló") y se agrupa por
// el afectado real, no por la regla.
var (
	reUnidad      = regexp.MustCompile(`[\w@.:\\-]+\.(service|socket|timer|mount|target|scope|path|slice)`)
	reOOM         = regexp.MustCompile(`Killed process \d+ \(([^)]+)\)|task=([\w.+-]+),pid`)
	reSegfault    = regexp.MustCompile(`^([\w./+-]+)\[\d+\]:\s*segfault|traps:\s*([\w./+-]+)\[\d+\]`)
	reDispositivo = regexp.MustCompile(`\b(sd[a-z]{1,2}|nvme\d+n\d+|mmcblk\d+|hd[a-z])\b`)
)

// sujeto extrae el objeto afectado por el error (servicio, programa o disco)
// según la regla que casó. Cadena vacía si no se puede identificar.
func sujeto(r *reglaLog, e entradaLog) string {
	switch r.id {
	case "servicio":
		if e.unit != "" {
			return e.unit
		}
		return primerGrupo(reUnidad.FindStringSubmatch(e.msg))
	case "oom":
		return primerGrupo(reOOM.FindStringSubmatch(e.msg))
	case "segfault":
		if s := primerGrupo(reSegfault.FindStringSubmatch(e.msg)); s != "" {
			return s
		}
		if e.ident != "" && e.ident != "kernel" {
			return e.ident
		}
	case "io", "ata", "medio", "fs":
		return primerGrupo(reDispositivo.FindStringSubmatch(e.msg))
	}
	return ""
}

// primerGrupo devuelve el primer grupo de captura no vacío de una coincidencia.
func primerGrupo(m []string) string {
	for i := 1; i < len(m); i++ {
		if m[i] != "" {
			return m[i]
		}
	}
	return ""
}

// clasifica devuelve la regla que explica el mensaje (o nil si no hay ninguna).
func clasifica(msg string) *reglaLog {
	for i := range reglasLog {
		if reglasLog[i].re.MatchString(msg) {
			return &reglasLog[i]
		}
	}
	return nil
}

// reNumeros normaliza el mensaje para agrupar repeticiones: los números, hexes y
// direcciones cambian en cada ocurrencia pero el problema es el mismo.
var reNumeros = regexp.MustCompile(`(0x)?[0-9a-fA-F]{3,}|\d+`)

// agrupaEntradas convierte las líneas de registro en errores interpretados,
// juntando las repeticiones en un solo elemento con su contador. Las entradas
// marcadas con soloRegla se descartan si no casan con el catálogo (vienen del
// barrido de avisos del kernel, que de otro modo sería puro ruido).
func agrupaEntradas(ents []entradaLog) []SystemError {
	orden := []string{}
	grupos := map[string]*SystemError{}
	for _, e := range ents {
		r := clasifica(e.texto())
		if r == nil && e.soloRegla {
			continue
		}
		if r == nil && descartable(e) {
			continue
		}
		clave, item := aError(e, r)
		g, ok := grupos[clave]
		if !ok {
			grupos[clave] = &item
			orden = append(orden, clave)
			continue
		}
		g.Count++
		// `ents` viene del más nuevo al más viejo: la primera vista es la última
		// ocurrencia; las siguientes van hacia atrás en el tiempo.
		if item.When < g.FirstWhen || g.FirstWhen == "" {
			g.FirstWhen = item.When
		}
		if item.When > g.When {
			g.When = item.When
		}
	}
	out := make([]SystemError, 0, len(orden))
	for _, k := range orden {
		g := grupos[k]
		if g.Count == 1 {
			g.FirstWhen = ""
		}
		out = append(out, *g)
	}
	return out
}

// descartable filtra ruido conocido que no ayuda al usuario (mensajes de
// depuración de escritorio, sesiones gráficas, etc.).
func descartable(e entradaLog) bool {
	id := strings.ToLower(e.ident)
	switch id {
	case "gnome-shell", "gdm-session-worker", "pulseaudio", "pipewire", "wireplumber",
		"tracker-miner-fs", "gvfsd", "dbus-daemon", "xdg-desktop-portal", "gnome-software":
		return true
	}
	msg := strings.ToLower(e.msg)
	return strings.Contains(msg, "gkr-message") ||
		strings.Contains(msg, "unable to init server") ||
		strings.Contains(msg, "couldn't connect to accessibility bus")
}

// aError arma el error interpretado a partir de la línea y su regla (si la hay).
func aError(e entradaLog, r *reglaLog) (string, SystemError) {
	fuente := e.ident
	if fuente == "" {
		fuente = "sistema"
	}
	if e.unit != "" {
		fuente = fmt.Sprintf("%s (%s)", fuente, e.unit)
	}
	item := SystemError{
		When:     fechaLocal(e.when),
		Count:    1,
		Severity: severidadPrio(e.prio),
		Kind:     KindSistema,
		Source:   fuente,
		Detail:   recorta(e.msg, 2000),
	}
	item.FirstWhen = item.When
	var clave string
	if r != nil {
		item.Kind = r.kind
		item.Severity = r.severity
		item.Title = r.title
		item.Cause = r.cause
		item.Fix = r.fix
		// Si se puede identificar al afectado (servicio, programa, disco), va en
		// el título y en la clave: así "falló un servicio" se convierte en
		// "falló cups.service" y cada servicio se agrupa por separado.
		if s := sujeto(r, e); s != "" {
			item.Title = r.title + ": " + s
			item.Culprit = s
			clave = "regla:" + r.id + "|" + strings.ToLower(s)
		} else {
			clave = "regla:" + r.id + "|" + strings.ToLower(e.ident)
		}
	} else {
		item.Title = tituloGenerico(e)
		item.Cause = "El sistema registró este error. No está en el catálogo de causas conocidas de PCInfo, " +
			"así que hay que leer el mensaje original de abajo."
		item.Fix = "Busca el texto del error junto con el nombre del programa o servicio que lo emitió. " +
			"Si es un servicio, revísalo con 'systemctl status " + primerCampo(e.unit, e.ident) + "'."
		clave = "libre:" + strings.ToLower(e.ident) + "|" + recorta(reNumeros.ReplaceAllString(e.msg, "#"), 90)
	}
	item.ID = clave
	return clave, item
}

func primerCampo(a, b string) string {
	if a != "" {
		return a
	}
	if b != "" {
		return b
	}
	return "<unidad>"
}

func tituloGenerico(e entradaLog) string {
	quien := e.ident
	if quien == "" {
		quien = "El sistema"
	}
	return quien + ": " + recorta(unaLinea(e.msg), 110)
}

func unaLinea(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	return strings.Join(strings.Fields(s), " ")
}

func severidadPrio(p int) string {
	switch {
	case p <= 2:
		return SevCritico
	case p == 3:
		return SevError
	default:
		return SevAviso
	}
}

func fechaLocal(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.Local().Format("2006-01-02 15:04:05")
}

// ---------------------------------------------------------------------------
// Programas caídos (systemd-coredump)
// ---------------------------------------------------------------------------

func agrupaCoredumps(ents []entradaLog) []SystemError {
	orden := []string{}
	grupos := map[string]*SystemError{}
	for _, e := range ents {
		exe := e.extra["exe"]
		if exe == "" {
			exe = e.extra["comm"]
		}
		if exe == "" {
			// Mensaje típico: "Process 1234 (firefox) of user 1000 dumped core."
			if m := regexp.MustCompile(`\(([^)]+)\)`).FindStringSubmatch(e.msg); m != nil {
				exe = m[1]
			}
		}
		if exe == "" {
			continue
		}
		nombre := filepath.Base(exe)
		senal := e.extra["sig"]
		clave := "core:" + nombre
		if g, ok := grupos[clave]; ok {
			g.Count++
			if f := fechaLocal(e.when); f != "" && f < g.FirstWhen {
				g.FirstWhen = f
			}
			continue
		}
		item := SystemError{
			ID:       clave,
			When:     fechaLocal(e.when),
			Count:    1,
			Severity: SevError,
			Kind:     KindApp,
			Title:    "El programa '" + nombre + "' se cerró de golpe (volcado de memoria)",
			Source:   "systemd-coredump",
			Code:     senal,
			Culprit:  exe,
			Cause: "La aplicación terminó de forma anormal" + textoSenal(senal) + " y el sistema guardó un volcado de memoria. " +
				"Suele ser un fallo del propio programa o de una biblioteca del sistema; si se repite con programas distintos, sospecha de la RAM.",
			Fix: "Actualiza o reinstala el programa. Puedes ver el detalle con 'coredumpctl info " + nombre +
				"'. Si fallan varios programas diferentes, prueba la memoria con memtest86+.",
			Detail: recorta(e.msg, 1000),
		}
		item.FirstWhen = item.When
		grupos[clave] = &item
		orden = append(orden, clave)
	}
	out := make([]SystemError, 0, len(orden))
	for _, k := range orden {
		g := grupos[k]
		if g.Count == 1 {
			g.FirstWhen = ""
		}
		out = append(out, *g)
	}
	return out
}

func textoSenal(s string) string {
	switch s {
	case "":
		return ""
	case "SIGSEGV":
		return " por una violación de segmento (accedió a memoria que no era suya)"
	case "SIGABRT":
		return " porque el propio programa abortó (assert o excepción sin capturar)"
	case "SIGILL":
		return " por una instrucción ilegal de CPU"
	case "SIGFPE":
		return " por una operación aritmética inválida"
	case "SIGBUS":
		return " por un error de bus (memoria o archivo mapeado inválido)"
	default:
		return " con la señal " + s
	}
}

// ---------------------------------------------------------------------------
// Arranques sin apagado limpio = apagón / cuelgue / botón de reset
// ---------------------------------------------------------------------------

// arranquesSucios revisa los últimos arranques y marca los que NO terminaron con
// un apagado ordenado: es el equivalente Linux del evento 6008 de Windows
// ("el sistema se apagó inesperadamente").
func arranquesSucios() []SystemError {
	out := []SystemError{}
	salida, err := corre("journalctl", "--list-boots", "--no-pager")
	if err != nil {
		return out
	}
	indices := []int{}
	for _, l := range strings.Split(salida, "\n") {
		campos := strings.Fields(l)
		if len(campos) < 2 {
			continue
		}
		n, err := strconv.Atoi(campos[0])
		if err != nil || n >= 0 {
			continue // el 0 es el arranque actual: aún no ha terminado
		}
		indices = append(indices, n)
	}
	// Solo los 6 arranques anteriores más recientes (el listado va de viejo a nuevo).
	if len(indices) > 6 {
		indices = indices[len(indices)-6:]
	}
	for _, n := range indices {
		out = append(out, revisaArranque(n)...)
	}
	return out
}

var marcasApagadoLimpio = []string{
	"reached target shutdown", "reached target power-off", "reached target reboot",
	"systemd-shutdown", "reboot: restarting system", "reboot: power down",
	"powering off", "shutting down", "unmounting", "system is powering down",
	"finished system power off", "starting power-off",
}

func revisaArranque(n int) []SystemError {
	salida, err := corre("journalctl", "-b", strconv.Itoa(n), "-n", "40", "-o", "json", "--no-pager")
	if err != nil {
		return nil
	}
	ents := parseaJournalJSON(salida)
	if len(ents) == 0 {
		return nil
	}
	for _, e := range ents {
		bajo := strings.ToLower(e.msg)
		for _, m := range marcasApagadoLimpio {
			if strings.Contains(bajo, m) {
				return nil // apagado ordenado: nada que reportar
			}
		}
	}
	ultima := ents[len(ents)-1]
	for _, e := range ents {
		if e.when.After(ultima.when) {
			ultima = e
		}
	}
	if time.Since(ultima.when) > time.Duration(diasAnalisis)*24*time.Hour {
		return nil
	}
	return []SystemError{{
		ID:       "apagado:" + strconv.Itoa(n),
		When:     fechaLocal(ultima.when),
		Count:    1,
		Severity: SevError,
		Kind:     KindApagado,
		Title:    "El equipo se apagó de forma inesperada",
		Source:   "journald (arranque " + strconv.Itoa(n) + ")",
		Cause: "El registro de ese arranque termina de golpe, sin las líneas del apagado ordenado: " +
			"corte de luz, botón de reset/apagado forzado, un cuelgue total o un fallo de la fuente de poder.",
		Fix: "Si no fue un corte de luz ni un apagado forzado a mano, revisa la fuente de poder y las temperaturas, " +
			"y busca justo antes de esta hora si hubo errores de hardware o del kernel en esta misma lista.",
		Detail: recorta("Última línea registrada antes del corte:\n"+ultima.msg, 800),
	}}
}

// ---------------------------------------------------------------------------
// Servicios en estado fallido (foto del ahora, no del historial)
// ---------------------------------------------------------------------------

func unidadesFallidas() []SystemError {
	if !tieneComando("systemctl") {
		return nil
	}
	salida, err := corre("systemctl", "--failed", "--no-legend", "--plain", "--no-pager")
	if err != nil {
		return nil
	}
	out := []SystemError{}
	ahora := fechaLocal(time.Now())
	for _, l := range strings.Split(salida, "\n") {
		campos := strings.Fields(l)
		if len(campos) == 0 || !strings.Contains(campos[0], ".") {
			continue
		}
		unidad := campos[0]
		out = append(out, SystemError{
			ID:       "unidad:" + unidad,
			When:     ahora,
			Count:    1,
			Severity: SevError,
			Kind:     KindServicio,
			Title:    "El servicio '" + unidad + "' está en estado FALLIDO ahora mismo",
			Source:   "systemctl --failed",
			Culprit:  unidad,
			Cause: "La unidad terminó con error y systemd la dejó marcada como fallida: puede ser configuración inválida, " +
				"una dependencia que no existe o que el programa se cae al arrancar.",
			Fix: "Revisa el motivo con 'systemctl status " + unidad + "' y 'journalctl -u " + unidad +
				" -b'. Tras corregir, reinícialo con 'systemctl restart " + unidad + "'.",
			Detail: unaLinea(l),
		})
	}
	return out
}

// ---------------------------------------------------------------------------
// Volcados presentes en el disco
// ---------------------------------------------------------------------------

func volcadosLinux() []DumpFile {
	out := []DumpFile{}
	dirs := []string{"/var/lib/systemd/coredump", "/var/crash"}
	for _, d := range dirs {
		ents, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, e := range ents {
			if e.IsDir() {
				continue
			}
			info, err := e.Info()
			if err != nil {
				continue
			}
			out = append(out, DumpFile{
				Path:      filepath.Join(d, e.Name()),
				When:      fechaLocal(info.ModTime()),
				SizeBytes: info.Size(),
			})
		}
	}
	if len(out) > 30 {
		out = out[:30]
	}
	return out
}

// ---------------------------------------------------------------------------
// Respaldo sin systemd: archivos de texto de /var/log
// ---------------------------------------------------------------------------

// reSyslog captura la fecha y el proceso de una línea clásica de syslog:
// "Jul 23 14:02:11 equipo kernel: mensaje".
var reSyslog = regexp.MustCompile(`^([A-Z][a-z]{2}\s+\d+\s+\d{2}:\d{2}:\d{2})\s+\S+\s+([^:\[]+)(\[\d+\])?:\s*(.*)$`)

func leeLogsTexto(desde time.Time) ([]entradaLog, error) {
	rutas := []string{"/var/log/syslog", "/var/log/messages", "/var/log/kern.log"}
	ents := []entradaLog{}
	var ultimoErr error
	leidoAlguno := false
	for _, r := range rutas {
		f, err := os.Open(r)
		if err != nil {
			if !os.IsNotExist(err) {
				ultimoErr = err
			}
			continue
		}
		leidoAlguno = true
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			m := reSyslog.FindStringSubmatch(sc.Text())
			if m == nil {
				continue
			}
			t := fechaSyslog(m[1])
			if t.Before(desde) {
				continue
			}
			e := entradaLog{when: t, msg: m[4], ident: strings.TrimSpace(m[2]), prio: 3}
			// Solo interesan las líneas que el catálogo sabe explicar: estos
			// archivos no traen prioridad, así que todo lo demás sería ruido puro.
			if clasifica(e.texto()) == nil {
				continue
			}
			ents = append(ents, e)
		}
		f.Close()
	}
	if !leidoAlguno {
		if ultimoErr == nil {
			ultimoErr = os.ErrNotExist
		}
		return nil, ultimoErr
	}
	// Se devuelven del más nuevo al más viejo, como hace journalctl aquí.
	for i, j := 0, len(ents)-1; i < j; i, j = i+1, j-1 {
		ents[i], ents[j] = ents[j], ents[i]
	}
	return ents, nil
}

// fechaSyslog interpreta "Jul 23 14:02:11" (syslog clásico no guarda el año):
// se asume el año actual y, si la fecha queda en el futuro, el anterior.
func fechaSyslog(s string) time.Time {
	ahora := time.Now()
	t, err := time.ParseInLocation("Jan 2 15:04:05", strings.Join(strings.Fields(s), " "), time.Local)
	if err != nil {
		return time.Time{}
	}
	t = t.AddDate(ahora.Year(), 0, 0)
	if t.After(ahora.Add(24 * time.Hour)) {
		t = t.AddDate(-1, 0, 0)
	}
	return t
}

// corre ejecuta un comando con timeout y devuelve su salida estándar.
func corre(nombre string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeoutLog)
	defer cancel()
	cmd := exec.CommandContext(ctx, nombre, args...)
	ocultaVentana(cmd)
	out, err := cmd.Output()
	if err != nil {
		return string(out), err
	}
	return string(out), nil
}
