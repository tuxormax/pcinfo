//go:build linux

package collector

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Tareas automáticas y programas de inicio (Linux). Ver arranques_linux.go para
// el porqué del módulo.

// Propiedades que se le piden a systemd de cada unidad. Se piden TODAS de una
// vez y para TODAS las unidades en una sola llamada: una llamada por unidad
// tardaría segundos en un equipo con muchos temporizadores.
var propsUnidad = []string{
	"Id", "Description", "ActiveState", "SubState", "UnitFileState", "Result",
	"ExecStart", "ExecMainStartTimestamp", "InactiveEnterTimestamp",
	"NextElapseUSecRealtime", "LastTriggerUSec", "TimersCalendar", "Unit", "WantedBy",
	"FragmentPath",
}

// Tope de unidades que se consultan de golpe, para no armar una línea de
// comando desmedida en un equipo con decenas de temporizadores.
const maxUnidades = 120

func leeTareasAuto(elevado bool) ([]AutoTask, string) {
	out := []AutoTask{}
	notas := []string{}

	if tieneComando("systemctl") {
		out = append(out, tareasTemporizadores()...)
		servicios := tareasServicios()
		out = append(out, servicios...)
		// Los temporizadores guardan su última ejecución en disco y sobreviven al
		// reinicio; los servicios NO: systemd empieza de cero en cada arranque.
		for _, s := range servicios {
			if s.AtShutdown {
				notas = append(notas, "La última ejecución de un SERVICIO solo se sabe dentro de "+
					"la sesión en curso: systemd la olvida al reiniciar. Por eso los que corren al "+
					"apagar el equipo aparecen sin ejecutar aunque hayan corrido.")
				break
			}
		}
	} else {
		notas = append(notas, "Este sistema no usa systemd: no hay temporizadores ni servicios que listar.")
	}

	cron, nota := tareasCron(elevado)
	out = append(out, cron...)
	if nota != "" {
		notas = append(notas, nota)
	}

	sort.SliceStable(out, func(i, j int) bool {
		if out[i].FromSystem != out[j].FromSystem {
			return !out[i].FromSystem // primero lo que se le añadió al equipo
		}
		return out[i].Name < out[j].Name
	})
	return out, strings.Join(notas, " ")
}

// ---------------------------------------------------------------------------
// systemd: temporizadores y servicios añadidos al equipo
// ---------------------------------------------------------------------------

func tareasTemporizadores() []AutoTask {
	salida, err := corre("systemctl", "list-unit-files", "--type=timer",
		"--no-legend", "--no-pager", "--plain")
	if err != nil {
		return nil
	}
	nombres := []string{}
	for _, l := range strings.Split(salida, "\n") {
		campos := strings.Fields(l)
		if len(campos) == 0 || !strings.HasSuffix(campos[0], ".timer") {
			continue
		}
		// Las unidades PLANTILLA (mdadm-last-resort@.timer) no se pueden
		// consultar: no son una tarea, son el molde del que systemd saca una
		// por dispositivo. Y no basta con ignorar su resultado — preguntar por
		// una hace que systemctl aborte y NO conteste por ninguna de las demás,
		// así que la lista entera de temporizadores salía vacía.
		if esPlantilla(campos[0]) {
			continue
		}
		nombres = append(nombres, campos[0])
	}
	if len(nombres) == 0 {
		return nil
	}
	datos := muestraUnidades(nombres)

	// Los servicios que disparan esos temporizadores, para saber cómo terminó
	// la última ejecución (el temporizador solo sabe CUÁNDO, no CON QUÉ RESULTADO).
	servicios := []string{}
	for _, d := range datos {
		if u := d["Unit"]; u != "" {
			servicios = append(servicios, u)
		}
	}
	datosSvc := muestraUnidades(servicios)

	out := []AutoTask{}
	for _, n := range nombres {
		d := datos[n]
		if d == nil {
			continue
		}
		svc := datosSvc[d["Unit"]]
		t := AutoTask{
			Name:        n,
			Kind:        TareaTemporizador,
			Description: d["Description"],
			Trigger:     horarioTimer(d["TimersCalendar"]),
			State:       estadoUnidad(d),
			LastRun:     fechaLocal(parseHoraSystemd(d["LastTriggerUSec"])),
			NextRun:     fechaLocal(parseHoraSystemd(d["NextElapseUSecRealtime"])),
			Source:      d["FragmentPath"],
			FromSystem:  esDelSistema(d["FragmentPath"]),
			AtShutdown:  correAlApagar(d["WantedBy"]),
		}
		if svc != nil {
			t.Command = comandoDe(svc["ExecStart"])
			// Un temporizador que nunca ha llegado a dispararse no tiene
			// resultado: el del servicio sería el de otra cosa que lo activó, y
			// poner "terminó correctamente" en una tarea que jamás corrió es
			// justo lo contrario de lo que hace falta saber.
			if t.LastRun != "" {
				t.Result = resultadoLlano(svc)
			}
			if t.LastRun == "" {
				t.LastRun = fechaLocal(parseHoraSystemd(svc["ExecMainStartTimestamp"]))
			}
			if svc["ActiveState"] == "failed" || (svc["Result"] != "" && svc["Result"] != "success") {
				t.State = EstadoFallido
			}
		}
		out = append(out, t)
	}
	return out
}

// tareasServicios lista los servicios que viven en /etc/systemd/system, que es
// donde caen los que se INSTALARON en este equipo a mano o desde un programa (el
// resto, los de los paquetes, están en /lib y /usr/lib). Justo ahí se ve un
// servicio enganchado al apagado: cuándo corrió por última vez y si terminó bien.
func tareasServicios() []AutoTask {
	rutas, err := filepath.Glob("/etc/systemd/system/*.service")
	if err != nil || len(rutas) == 0 {
		return nil
	}
	nombres := []string{}
	for _, r := range rutas {
		// Los enlaces simbólicos son unidades de paquete solo habilitadas aquí:
		// no son "propias del equipo" y saldrían duplicadas.
		if fi, err := os.Lstat(r); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			continue
		}
		if base := filepath.Base(r); !esPlantilla(base) {
			nombres = append(nombres, base)
		}
	}
	if len(nombres) == 0 {
		return nil
	}
	datos := muestraUnidades(nombres)

	out := []AutoTask{}
	for _, n := range nombres {
		d := datos[n]
		if d == nil {
			continue
		}
		t := AutoTask{
			Name:        n,
			Kind:        TareaServicio,
			Description: d["Description"],
			Trigger:     disparoDe(d),
			Command:     comandoDe(d["ExecStart"]),
			State:       estadoUnidad(d),
			LastRun:     ultimaEjecucion(d),
			Source:      d["FragmentPath"],
			FromSystem:  false,
			AtShutdown:  correAlApagar(d["WantedBy"]),
		}
		// Sin ejecución no hay resultado que contar: el "success" que systemd
		// deja por defecto haría creer que una tarea que jamás corrió terminó
		// correctamente.
		if t.LastRun != "" {
			t.Result = resultadoLlano(d)
		}
		out = append(out, t)
	}
	return out
}

// muestraUnidades pregunta a systemd por varias unidades de una sola vez y
// devuelve, por nombre de unidad, sus propiedades.
//
// Se pide con --timestamp=unix para que las horas salgan como número y no
// dependan del idioma del sistema; si esa opción no existe (systemd antiguo) se
// reintenta sin ella y las fechas se leen con expresión regular.
func muestraUnidades(unidades []string) map[string]map[string]string {
	res := map[string]map[string]string{}
	unidades = sinDuplicados(unidades)
	if len(unidades) == 0 {
		return res
	}
	if len(unidades) > maxUnidades {
		unidades = unidades[:maxUnidades]
	}
	base := []string{"show", "--no-pager"}
	for _, p := range propsUnidad {
		base = append(base, "-p", p)
	}
	args := append([]string{"show", "--no-pager", "--timestamp=unix"}, base[2:]...)
	args = append(args, unidades...)
	// La salida se aprovecha AUNQUE systemctl devuelva error: basta con que una
	// unidad de la lista no exista para que termine con código distinto de cero,
	// y perder por eso las otras veinte que sí contestó sería absurdo.
	salida, _ := corre("systemctl", args...)
	if !strings.Contains(salida, "Id=") {
		salida, _ = corre("systemctl", append(append([]string{}, base...), unidades...)...)
		if !strings.Contains(salida, "Id=") {
			return res
		}
	}
	for _, bloque := range strings.Split(salida, "\n\n") {
		props := map[string]string{}
		for _, l := range strings.Split(bloque, "\n") {
			k, v, ok := strings.Cut(strings.TrimSpace(l), "=")
			if !ok || k == "" {
				continue
			}
			props[k] = v
		}
		if id := props["Id"]; id != "" {
			res[id] = props
		}
	}
	return res
}

// esPlantilla reconoce las unidades molde de systemd ("algo@.service"), que no
// representan una tarea concreta y no se pueden consultar.
func esPlantilla(unidad string) bool {
	return strings.Contains(unidad, "@.")
}

func sinDuplicados(in []string) []string {
	visto := map[string]bool{}
	out := []string{}
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" || visto[s] {
			continue
		}
		visto[s] = true
		out = append(out, s)
	}
	return out
}

func estadoUnidad(d map[string]string) string {
	switch d["UnitFileState"] {
	case "disabled", "masked":
		return EstadoDeshabilitado
	}
	if d["ActiveState"] == "failed" {
		return EstadoFallido
	}
	if r := d["Result"]; r != "" && r != "success" {
		return EstadoFallido
	}
	if d["UnitFileState"] == "" && d["ActiveState"] == "" {
		return EstadoDesconocido
	}
	return EstadoActivo
}

// disparoDe traduce a español llano el momento en que se ejecuta un servicio.
// Es la diferencia entre leer "WantedBy=shutdown.target" y leer "al apagar el
// equipo", que es lo que hace falta para entender por qué algo no corrió.
func disparoDe(d map[string]string) string {
	w := strings.ToLower(d["WantedBy"])
	switch {
	case w == "":
		if d["UnitFileState"] == "static" {
			return "Cuando otro servicio lo necesita"
		}
		return ""
	case strings.Contains(w, "shutdown.target"), strings.Contains(w, "halt.target"),
		strings.Contains(w, "poweroff.target"), strings.Contains(w, "reboot.target"):
		return "Al apagar o reiniciar el equipo"
	case strings.Contains(w, "timers.target"):
		return "Cuando lo dispara su temporizador"
	case strings.Contains(w, "default.target"):
		return "Al iniciar sesión"
	case strings.Contains(w, "multi-user.target"), strings.Contains(w, "graphical.target"),
		strings.Contains(w, "sysinit.target"), strings.Contains(w, "basic.target"):
		return "Al arrancar el equipo"
	}
	return "Con " + d["WantedBy"]
}

var reArgv = regexp.MustCompile(`argv\[\]=([^;]*)`)
var reOnCalendar = regexp.MustCompile(`OnCalendar=([^;}]*)`)

// horarioTimer traduce el calendario de systemd ("*-*-* 06:00:00", "Mon *-*-*
// 00:00:00", "daily") a una frase entendible. Lo que no encaje en un patrón
// conocido se devuelve tal cual: mostrar el horario crudo es preferible a
// inventar una traducción que diga otra hora.
func horarioTimer(cal string) string {
	m := reOnCalendar.FindStringSubmatch(cal)
	if m == nil {
		return "Cuando llega su hora programada"
	}
	v := strings.TrimSpace(m[1])
	if v == "" {
		return "Cuando llega su hora programada"
	}
	switch strings.ToLower(v) {
	case "hourly":
		return "Cada hora"
	case "daily":
		return "Todos los días a medianoche"
	case "weekly":
		return "Una vez por semana"
	case "monthly":
		return "Una vez al mes"
	case "yearly", "annually":
		return "Una vez al año"
	}
	campos := strings.Fields(v)
	dia := ""
	if len(campos) == 3 {
		dia = traduceDiaSystemd(campos[0])
		if dia == "" {
			return v
		}
		campos = campos[1:]
	}
	if len(campos) != 2 || campos[0] != "*-*-*" {
		return v
	}
	hms := strings.Split(campos[1], ":")
	if len(hms) != 3 || hms[2] != "00" {
		return v
	}
	cuando := ""
	switch {
	case hms[0] == "*" && hms[1] == "00":
		cuando = "cada hora en punto"
	case hms[0] == "*":
		cuando = "cada hora, en el minuto " + hms[1]
	case strings.ContainsAny(hms[0], "*/.,") || strings.ContainsAny(hms[1], "*/.,"):
		return v
	default:
		cuando = "a las " + hms[0] + ":" + hms[1]
	}
	if dia != "" {
		return "Cada " + dia + " " + cuando
	}
	if strings.HasPrefix(cuando, "cada") {
		return strings.ToUpper(cuando[:1]) + cuando[1:]
	}
	return "Todos los días " + cuando
}

var diasSystemd = map[string]string{
	"mon": "lunes", "tue": "martes", "wed": "miércoles", "thu": "jueves",
	"fri": "viernes", "sat": "sábado", "sun": "domingo",
}

func traduceDiaSystemd(d string) string {
	return diasSystemd[strings.ToLower(strings.TrimSuffix(d, ","))]
}

// comandoDe saca el comando legible de la propiedad ExecStart, que systemd
// entrega envuelta en su propia estructura.
func comandoDe(exec string) string {
	if exec == "" {
		return ""
	}
	if m := reArgv.FindStringSubmatch(exec); m != nil {
		return strings.TrimSpace(m[1])
	}
	return recorta(exec, 200)
}

func ultimaEjecucion(d map[string]string) string {
	if t := parseHoraSystemd(d["ExecMainStartTimestamp"]); !t.IsZero() {
		return fechaLocal(t)
	}
	return fechaLocal(parseHoraSystemd(d["InactiveEnterTimestamp"]))
}

func resultadoLlano(d map[string]string) string {
	switch d["Result"] {
	case "success":
		return "Terminó correctamente"
	case "exit-code":
		return "Terminó con error"
	case "timeout":
		return "Se pasó del tiempo límite"
	case "signal":
		return "Se interrumpió"
	case "core-dump":
		return "Se cayó"
	case "resources", "start-limit-hit":
		return "No pudo arrancar"
	case "":
		return ""
	}
	return d["Result"]
}

func esDelSistema(ruta string) bool {
	return strings.HasPrefix(ruta, "/lib/") || strings.HasPrefix(ruta, "/usr/lib/") ||
		strings.HasPrefix(ruta, "/run/")
}

var reHoraISO = regexp.MustCompile(`(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})`)

// parseHoraSystemd entiende las dos formas en que systemd entrega una marca de
// tiempo: "@1788697820" (con --timestamp=unix) y la fecha con día de la semana
// y zona horaria del idioma del sistema.
func parseHoraSystemd(v string) time.Time {
	v = strings.TrimSpace(v)
	if v == "" || v == "n/a" || v == "0" {
		return time.Time{}
	}
	if strings.HasPrefix(v, "@") {
		seg, err := strconv.ParseInt(strings.TrimPrefix(v, "@"), 10, 64)
		if err != nil || seg <= 0 {
			return time.Time{}
		}
		return time.Unix(seg, 0)
	}
	if m := reHoraISO.FindString(v); m != "" {
		return horaLocalDe(m)
	}
	return time.Time{}
}

// ---------------------------------------------------------------------------
// cron
// ---------------------------------------------------------------------------

func tareasCron(elevado bool) ([]AutoTask, string) {
	out := []AutoTask{}
	perdidas := false

	archivos := []string{"/etc/crontab"}
	if g, err := filepath.Glob("/etc/cron.d/*"); err == nil {
		archivos = append(archivos, g...)
	}
	for _, f := range archivos {
		datos, err := os.ReadFile(f)
		if err != nil {
			if !os.IsNotExist(err) {
				perdidas = true
			}
			continue
		}
		out = append(out, parseaCrontab(string(datos), f, true)...)
	}
	// Los crontabs personales solo los puede leer root.
	if g, err := filepath.Glob("/var/spool/cron/crontabs/*"); err == nil {
		for _, f := range g {
			datos, err := os.ReadFile(f)
			if err != nil {
				perdidas = true
				continue
			}
			out = append(out, parseaCrontab(string(datos), f, false)...)
		}
	} else if !elevado {
		perdidas = true
	}
	// Carpetas de ejecución periódica: cada script de dentro es una tarea.
	for _, dir := range []string{"hourly", "daily", "weekly", "monthly"} {
		g, err := filepath.Glob("/etc/cron." + dir + "/*")
		if err != nil {
			continue
		}
		for _, f := range g {
			fi, err := os.Stat(f)
			// Solo scripts ejecutables: en esas carpetas también hay archivos
			// sueltos (.placeholder, copias .dpkg-old) que cron ni mira.
			if err != nil || fi.IsDir() || fi.Mode()&0o111 == 0 ||
				strings.HasPrefix(filepath.Base(f), ".") {
				continue
			}
			out = append(out, AutoTask{
				Name:       filepath.Base(f),
				Kind:       TareaCron,
				Trigger:    periodicidadCarpeta(dir),
				Command:    f,
				State:      EstadoActivo,
				Source:     f,
				FromSystem: true,
			})
		}
	}
	nota := ""
	if perdidas && !elevado {
		nota = "Puede faltar alguna tarea de cron: los crontabs de cada usuario solo los " +
			"puede leer el administrador."
	}
	return out, nota
}

func periodicidadCarpeta(dir string) string {
	switch dir {
	case "hourly":
		return "Cada hora"
	case "daily":
		return "Todos los días"
	case "weekly":
		return "Una vez por semana"
	case "monthly":
		return "Una vez al mes"
	}
	return dir
}

// parseaCrontab entiende las dos formas del archivo: la del sistema, que lleva
// el usuario antes del comando (/etc/crontab, /etc/cron.d), y la personal, que
// no lo lleva.
func parseaCrontab(texto, origen string, conUsuario bool) []AutoTask {
	out := []AutoTask{}
	delSistema := strings.HasPrefix(origen, "/etc/")
	dueno := ""
	if !conUsuario {
		dueno = filepath.Base(origen)
	}
	for _, cruda := range strings.Split(texto, "\n") {
		l := strings.TrimSpace(cruda)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		// Las asignaciones de entorno (PATH=, SHELL=, MAILTO=) no son tareas.
		if i := strings.Index(l, "="); i > 0 && !strings.ContainsAny(l[:i], " \t") {
			continue
		}
		campos := strings.Fields(l)
		cuando, resto := "", []string{}
		if strings.HasPrefix(campos[0], "@") {
			if len(campos) < 2 {
				continue
			}
			cuando = describeAtajoCron(campos[0])
			resto = campos[1:]
		} else {
			if len(campos) < 6 {
				continue
			}
			cuando = describeCron(campos[:5])
			resto = campos[5:]
		}
		if conUsuario && len(resto) > 1 {
			dueno = resto[0]
			resto = resto[1:]
		}
		comando := strings.Join(resto, " ")
		if comando == "" {
			continue
		}
		// El nombre sale del ARCHIVO, no del comando: muchas líneas de cron
		// empiezan por "test -x …" o "cd / && …" y bautizar la tarea con eso
		// deja una lista de entradas llamadas "test" y "cd", inservible.
		nombre := nombreCrontab(origen)
		if dueno != "" && conUsuario {
			nombre += " · " + dueno
		}
		out = append(out, AutoTask{
			Name:    nombre,
			Kind:    TareaCron,
			Trigger: cuando,
			Command: recorta(comando, 300),
			State:   EstadoActivo,
			Source:  origen,
			// "Añadida a este equipo" es solo lo que alguien puso a mano: el
			// crontab del sistema y los personales. /etc/cron.d lo llenan los
			// paquetes (php, sysstat, anacron) y colarlo ahí ahogaría lo propio,
			// que es justo lo que se viene a buscar.
			FromSystem: delSistema &&
				(strings.HasPrefix(origen, "/etc/cron.d/") || esFontaneriaCron(comando)),
		})
	}
	return out
}

// correAlApagar dice si la unidad está enganchada al apagado del equipo.
func correAlApagar(wantedBy string) bool {
	w := strings.ToLower(wantedBy)
	return strings.Contains(w, "shutdown.target") || strings.Contains(w, "halt.target") ||
		strings.Contains(w, "poweroff.target") || strings.Contains(w, "reboot.target")
}

// esFontaneriaCron reconoce las cuatro líneas que Debian y Ubuntu traen de
// fábrica en /etc/crontab: las que van corriendo las carpetas cron.hourly,
// cron.daily, cron.weekly y cron.monthly. No las puso nadie de este equipo, así
// que colarlas entre "las añadidas" deja cinco entradas donde solo hay una.
func esFontaneriaCron(comando string) bool {
	return strings.Contains(comando, "run-parts") && strings.Contains(comando, "/etc/cron.")
}

// nombreCrontab pone nombre a una línea de cron según de dónde salió.
func nombreCrontab(origen string) string {
	switch {
	case origen == "/etc/crontab":
		return "crontab del sistema"
	case strings.HasPrefix(origen, "/var/spool/cron/crontabs/"):
		return "crontab de " + filepath.Base(origen)
	}
	return filepath.Base(origen)
}

func describeAtajoCron(a string) string {
	switch strings.ToLower(a) {
	case "@reboot":
		return "Cada vez que arranca el equipo"
	case "@yearly", "@annually":
		return "Una vez al año"
	case "@monthly":
		return "Una vez al mes"
	case "@weekly":
		return "Una vez por semana"
	case "@daily", "@midnight":
		return "Todos los días a medianoche"
	case "@hourly":
		return "Cada hora"
	}
	return a
}

var diasSemana = []string{"domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"}

// describeCron traduce los cinco campos de cron a una frase entendible. Los
// casos raros (listas, pasos, rangos) se devuelven tal cual: es preferible
// mostrar el horario crudo a inventar una traducción equivocada.
func describeCron(c []string) string {
	min, hora, dia, mes, sem := c[0], c[1], c[2], c[3], c[4]
	simple := func(s string) bool {
		_, err := strconv.Atoi(s)
		return err == nil
	}
	hhmm := func() string {
		return pad2(hora) + ":" + pad2(min)
	}
	switch {
	case simple(min) && simple(hora) && dia == "*" && mes == "*" && sem == "*":
		return "Todos los días a las " + hhmm()
	case simple(min) && simple(hora) && dia == "*" && mes == "*" && simple(sem):
		n, _ := strconv.Atoi(sem)
		if n >= 0 && n <= 6 {
			return "Cada " + diasSemana[n] + " a las " + hhmm()
		}
	case simple(min) && simple(hora) && simple(dia) && mes == "*" && sem == "*":
		return "El día " + dia + " de cada mes a las " + hhmm()
	case simple(min) && hora == "*" && dia == "*" && mes == "*" && sem == "*":
		return "Cada hora, en el minuto " + min
	case min == "*" && hora == "*" && dia == "*" && mes == "*" && sem == "*":
		return "Cada minuto"
	}
	return strings.Join(c, " ")
}

func pad2(s string) string {
	if len(s) == 1 {
		return "0" + s
	}
	return s
}
