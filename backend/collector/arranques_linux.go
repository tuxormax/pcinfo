//go:build linux

package collector

import (
	"encoding/json"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Encendidos y apagados en Linux. Fuentes:
//
//	last (registro de accesos)→ el historial de encendidos y apagados que SÍ
//	                            sobrevive a los reinicios (/var/log/wtmp)
//	journalctl --list-boots   → una entrada por encendido, con su primera y su
//	                            última línea registradas
//	journalctl -b N (final)   → CÓMO terminó esa sesión: si el registro llega a
//	                            las líneas del apagado ordenado o se corta seco
//
// ⛔ El diario del sistema NO sirve como única fuente: en Linux Mint (y en
// Ubuntu por defecto) journald es VOLÁTIL —vive en /run y se borra en cada
// apagado— así que solo conoce la sesión en curso. Preguntándole a él, un equipo
// que lleva años funcionando parece recién estrenado. El registro de accesos
// (wtmp) sí es persistente y guarda un mes: de ahí salen las sesiones, y el
// diario solo añade el detalle de las que alcanza a recordar.
//	systemctl list-unit-files → temporizadores del sistema
//	/etc/systemd/system/*.service → los servicios que se le AÑADIERON al equipo
//	/etc/crontab, /etc/cron.d, /etc/cron.*, crontabs de usuario → tareas de cron
//	/etc/xdg/autostart, ~/.config/autostart → programas al iniciar sesión
//
// Windows tiene su propio archivo (todavía sin implementar): allí lo mismo sale
// del registro de eventos (6005/6006/6008/1074/41) y del Programador de tareas.

func collectBoots() BootsReport {
	rep := BootsReport{
		OS:       runtime.GOOS,
		Elevated: isElevated(),
		ScanDays: diasAnalisis,
		Source:   "registro de accesos (wtmp), journald, systemd y cron",
		Sessions: []BootSession{},
		Tasks:    []AutoTask{},
		Startup:  []StartupItem{},
	}

	rep.JournalVolatile = !journalPersistente()
	rep.Sessions, rep.SessionsNote = leeSesiones()
	rep.Available = len(rep.Sessions) > 0
	if !rep.Available {
		rep.Reason = "No se pudo leer el historial de encendidos: ni el registro de accesos " +
			"(/var/log/wtmp) ni el diario del sistema dieron resultados. PCInfo puede " +
			"necesitar ejecutarse como administrador para verlos."
	}

	rep.Tasks, rep.TasksNote = leeTareasAuto(rep.Elevated)
	rep.Startup, rep.StartupNote = leeProgramasInicio()
	return rep
}

// ---------------------------------------------------------------------------
// Sesiones: del encendido al apagado
// ---------------------------------------------------------------------------

// bootRango es lo que journalctl sabe de un arranque antes de mirar su final.
type bootRango struct {
	idx      int
	ini, fin time.Time
}

// leeSesiones arma el historial de sesiones. La lista sale del registro de
// accesos (persistente) y el diario del sistema solo aporta el detalle de las
// sesiones que todavía recuerda: con qué núcleo arrancó, si el final fue un
// reinicio o un apagado, y la última línea escrita antes de un corte brusco.
func leeSesiones() ([]BootSession, string) {
	ses := sesionesWtmp()
	boots := listaBoots()
	if len(ses) == 0 {
		ses = sesionesJournal(boots)
		if len(ses) == 0 {
			return nil, ""
		}
	} else {
		enriqueceConJournal(ses, boots)
	}
	if len(ses) > maxSesiones {
		ses = ses[:maxSesiones]
	}
	nota := ""
	if !journalPersistente() {
		nota = "El diario del sistema de este equipo es volátil: se borra en cada apagado, " +
			"así que de las sesiones anteriores solo consta la hora de encendido y de apagado, " +
			"sin el detalle de lo que ocurrió. Para conservarlo hay que crear la carpeta " +
			"/var/log/journal."
	}
	return ses, nota
}

// journalPersistente dice si el diario del sistema se guarda en disco. Cuando no
// lo está —el caso por defecto en Mint y Ubuntu— journald solo sabe de la sesión
// en curso, y hay que decírselo al usuario para que no lea la lista como si
// faltaran datos por un fallo.
func journalPersistente() bool {
	fi, err := os.Stat("/var/log/journal")
	return err == nil && fi.IsDir()
}

// Marcas del registro de accesos: "still running" es la sesión en curso y
// "crash" es como el propio `last` llama a un encendido que nunca vio su
// apagado, que es exactamente un corte brusco.
var reISO = regexp.MustCompile(`\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}`)

// sesionesWtmp lee el historial persistente de encendidos y apagados con `last`.
// Se pide en formato ISO (--time-format=iso) para que las fechas no dependan del
// idioma del sistema: con el formato de siempre, los nombres de mes salen
// traducidos y no hay forma fiable de interpretarlos.
func sesionesWtmp() []BootSession {
	if !tieneComando("last") {
		return nil
	}
	salida, err := corre("last", "--time-format=iso", "-x", "reboot", "shutdown")
	if err != nil && !strings.Contains(salida, "reboot") {
		return nil
	}
	return parseaSalidaLast(salida, time.Now())
}

// parseaSalidaLast interpreta la salida de `last`. Va aparte para poder
// probarla con historiales de ejemplo: es la lógica de la que sale el dato
// central del módulo —si un apagado fue ordenado o un tirón— y equivocarse ahí
// se ve como un equipo sano que en realidad se está apagando mal.
func parseaSalidaLast(salida string, ahora time.Time) []BootSession {
	type cruda struct {
		ini, fin time.Time
		kernel   string
		corte    bool
		enCurso  bool
	}
	arranques := []cruda{}
	apagados := map[int64]bool{} // inicio (unix) de cada apagado ordenado

	for _, l := range strings.Split(salida, "\n") {
		campos := strings.Fields(l)
		if len(campos) < 4 {
			continue
		}
		fechas := reISO.FindAllString(l, -1)
		if len(fechas) == 0 {
			continue
		}
		t0 := horaISO(fechas[0])
		if t0.IsZero() {
			continue
		}
		switch {
		case campos[0] == "shutdown":
			apagados[t0.Unix()] = true
		case campos[0] == "reboot":
			// "reboot system boot <núcleo> <fecha>…" — el registro de accesos
			// recorta el nombre del núcleo a 16 caracteres; se muestra tal cual
			// porque sigue sirviendo para ver que cambió entre dos sesiones.
			c := cruda{ini: t0, kernel: campos[3]}
			c.enCurso = strings.Contains(l, "still running")
			c.corte = strings.Contains(l, "crash")
			if len(fechas) > 1 {
				c.fin = horaISO(fechas[1])
			}
			arranques = append(arranques, c)
		}
	}
	if len(arranques) == 0 {
		return nil
	}

	// `last` imprime de lo más nuevo a lo más viejo, que es el orden en que se
	// quiere leer un historial: se conserva.
	out := []BootSession{}
	corte := ahora.AddDate(0, 0, -diasAnalisis)
	for i, a := range arranques {
		// Una sesión que terminó de golpe NO tiene hora de apagado, así que para
		// decidir si cae fuera de la ventana hay que mirar su encendido: si no,
		// un corte de hace años seguiría saliendo en "los últimos 30 días".
		fecha := a.fin
		if fecha.IsZero() {
			fecha = a.ini
		}
		if !a.enCurso && fecha.Before(corte) {
			continue
		}
		s := BootSession{
			Index:  -i, // 0 = la actual; hacia atrás, números negativos
			Start:  fechaLocal(a.ini),
			Kernel: a.kernel,
		}
		switch {
		case a.enCurso:
			s.Ended = FinEnCurso
			s.SecondsUp = int64(ahora.Sub(a.ini).Seconds())
			s.Note = "Es la sesión en curso: el equipo lleva " + duracionLlana(s.SecondsUp) + " encendido."
		case a.corte || a.fin.IsZero():
			s.Ended = FinBrusco
			s.End = fechaLocal(a.fin)
		default:
			s.End = fechaLocal(a.fin)
			s.Ended = FinNormal
			if !apagados[a.fin.Unix()] {
				// El registro cierra la sesión pero no hay un apagado que lo
				// respalde: se cortó y `last` puso la última hora que vio.
				s.Ended = FinBrusco
			}
			// Un apagado seguido de un encendido casi inmediato es un reinicio.
			if s.Ended == FinNormal && i > 0 {
				anterior := arranques[i-1].ini
				if anterior.Sub(a.fin) >= 0 && anterior.Sub(a.fin) < 90*time.Second {
					s.Ended = FinReinicio
				}
			}
		}
		if !a.ini.IsZero() && !a.fin.IsZero() && s.SecondsUp == 0 {
			s.SecondsUp = int64(a.fin.Sub(a.ini).Seconds())
		}
		if s.Note == "" {
			s.Note = notaFin(s.Ended)
		}
		out = append(out, s)
	}
	return out
}

func horaISO(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t.Local()
}

// Cuántas sesiones se enriquecen con el diario: cada una cuesta dos consultas a
// journalctl y solo las más recientes suelen seguir ahí.
const maxEnriquecidas = 10

// enriqueceConJournal completa las sesiones que el diario todavía recuerda: si
// el final fue un reinicio o un apagado, y qué se registró justo antes de un
// corte brusco. Se emparejan por hora de encendido, con holgura de dos minutos
// (el registro de accesos y el diario no anotan el arranque en el mismo instante).
func enriqueceConJournal(ses []BootSession, boots []bootRango) {
	if len(boots) == 0 {
		return
	}
	hechas := 0
	for i := range ses {
		if hechas >= maxEnriquecidas {
			return
		}
		if ses[i].Ended == FinEnCurso {
			continue
		}
		ini := horaLocalDe(ses[i].Start)
		if ini.IsZero() {
			continue
		}
		idx, ok := 0, false
		for _, b := range boots {
			if dif := b.ini.Sub(ini); dif > -2*time.Minute && dif < 2*time.Minute {
				idx, ok = b.idx, true
				break
			}
		}
		if !ok || idx >= 0 {
			continue
		}
		hechas++
		fin, ultima := comoTermino(idx)
		ses[i].Ended = fin
		ses[i].LastLine = ultima
		ses[i].Note = notaFin(fin)
		if ses[i].Kernel == "" {
			ses[i].Kernel = kernelDeBoot(idx)
		}
	}
}

// sesionesJournal es el camino de respaldo: sin `last` (o sin /var/log/wtmp) el
// diario del sistema es lo único que queda, aunque solo alcance para la sesión
// en curso cuando es volátil.
func sesionesJournal(rangos []bootRango) []BootSession {
	if len(rangos) == 0 {
		return nil
	}
	if len(rangos) > maxSesiones {
		rangos = rangos[len(rangos)-maxSesiones:]
	}
	corte := time.Now().AddDate(0, 0, -diasAnalisis)
	out := []BootSession{}
	for i := len(rangos) - 1; i >= 0; i-- {
		r := rangos[i]
		if !r.fin.IsZero() && r.fin.Before(corte) {
			continue
		}
		s := BootSession{
			Index:  r.idx,
			Start:  fechaLocal(r.ini),
			Kernel: kernelDeBoot(r.idx),
		}
		if r.idx >= 0 {
			s.Ended = FinEnCurso
			s.SecondsUp = int64(time.Since(r.ini).Seconds())
			s.Note = "Es la sesión en curso: el equipo lleva " + duracionLlana(s.SecondsUp) + " encendido."
			out = append(out, s)
			continue
		}
		s.End = fechaLocal(r.fin)
		if !r.ini.IsZero() && !r.fin.IsZero() {
			s.SecondsUp = int64(r.fin.Sub(r.ini).Seconds())
		}
		s.Ended, s.LastLine = comoTermino(r.idx)
		s.Note = notaFin(s.Ended)
		out = append(out, s)
	}
	return out
}

// listaBoots devuelve los arranques que conoce journald, del más viejo al más
// nuevo. Se intenta primero la salida JSON (systemd reciente) y, si no está, se
// cae al listado de texto: de ahí se sacan el índice y las dos fechas con una
// expresión regular, porque el formato de esa tabla ha cambiado entre versiones
// (systemd 254 le añadió cabecera) y las columnas no se pueden partir a ciegas.
func listaBoots() []bootRango {
	if out, err := corre("journalctl", "--list-boots", "-o", "json", "--no-pager"); err == nil {
		if r := parseaBootsJSON(out); len(r) > 0 {
			return r
		}
	}
	out, err := corre("journalctl", "--list-boots", "--no-pager")
	if err != nil {
		return nil
	}
	return parseaBootsTexto(out)
}

func parseaBootsJSON(out string) []bootRango {
	var arr []map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &arr); err != nil {
		return nil
	}
	res := []bootRango{}
	for _, m := range arr {
		r := bootRango{
			idx: int(numeroJSON(m["index"])),
			ini: deMicros(numeroJSON(m["first_entry"])),
			fin: deMicros(numeroJSON(m["last_entry"])),
		}
		if r.ini.IsZero() {
			continue
		}
		res = append(res, r)
	}
	ordenaRangos(res)
	return res
}

// numeroJSON acepta el valor venga como número o como texto: distintas versiones
// de systemd serializan las marcas de tiempo de una forma o de la otra.
func numeroJSON(v any) int64 {
	switch t := v.(type) {
	case float64:
		return int64(t)
	case string:
		n, _ := strconv.ParseInt(strings.TrimSpace(t), 10, 64)
		return n
	}
	return 0
}

// deMicros convierte los microsegundos desde época que usa journald.
func deMicros(us int64) time.Time {
	if us <= 0 {
		return time.Time{}
	}
	return time.Unix(us/1_000_000, (us%1_000_000)*1000)
}

var reIndiceBoot = regexp.MustCompile(`^\s*(-?\d+)\s`)
var reFechaBoot = regexp.MustCompile(`(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})`)

func parseaBootsTexto(out string) []bootRango {
	res := []bootRango{}
	for _, l := range strings.Split(out, "\n") {
		m := reIndiceBoot.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		idx, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		fechas := reFechaBoot.FindAllString(l, -1)
		r := bootRango{idx: idx}
		if len(fechas) > 0 {
			r.ini = horaLocalDe(fechas[0])
		}
		if len(fechas) > 1 {
			r.fin = horaLocalDe(fechas[1])
		}
		if r.ini.IsZero() {
			continue
		}
		res = append(res, r)
	}
	ordenaRangos(res)
	return res
}

func ordenaRangos(r []bootRango) {
	for i := 1; i < len(r); i++ {
		for j := i; j > 0 && r[j].idx < r[j-1].idx; j-- {
			r[j], r[j-1] = r[j-1], r[j]
		}
	}
}

func horaLocalDe(s string) time.Time {
	t, err := time.ParseInLocation("2006-01-02 15:04:05", s, time.Local)
	if err != nil {
		return time.Time{}
	}
	return t
}

// Marcas de un apagado ordenado. Se buscan en las últimas líneas de la sesión:
// si NINGUNA aparece, el registro se cortó de golpe.
var marcasReinicio = []string{
	"reboot: restarting system", "reached target reboot", "starting reboot",
	"systemd-shutdown: rebooting", "rebooting.",
}

var marcasApagado = []string{
	"reboot: power down", "reached target power-off", "powering off",
	"system is powering down", "finished system power off", "starting power-off",
	"reached target shutdown", "systemd-shutdown", "unmounting", "shutting down",
	"halting.",
}

// comoTermino mira el FINAL del registro de esa sesión. Devuelve el tipo de fin
// y, cuando fue brusco, la última línea que alcanzó a escribirse: es lo único
// que queda para saber qué estaba haciendo el equipo justo antes.
func comoTermino(n int) (string, string) {
	salida, err := corre("journalctl", "-b", strconv.Itoa(n), "-n", "60", "-o", "json", "--no-pager")
	if err != nil {
		return FinBrusco, ""
	}
	ents := parseaJournalJSON(salida)
	if len(ents) == 0 {
		return FinBrusco, ""
	}
	for _, e := range ents {
		bajo := strings.ToLower(e.msg)
		for _, m := range marcasReinicio {
			if strings.Contains(bajo, m) {
				return FinReinicio, ""
			}
		}
	}
	for _, e := range ents {
		bajo := strings.ToLower(e.msg)
		for _, m := range marcasApagado {
			if strings.Contains(bajo, m) {
				return FinNormal, ""
			}
		}
	}
	ultima := ents[len(ents)-1]
	for _, e := range ents {
		if e.when.After(ultima.when) {
			ultima = e
		}
	}
	return FinBrusco, recorta(ultima.msg, 400)
}

func notaFin(tipo string) string {
	switch tipo {
	case FinNormal:
		return "El equipo se apagó con normalidad: el registro llega hasta las líneas del apagado ordenado."
	case FinReinicio:
		return "Fue un reinicio ordenado, no un apagado."
	case FinBrusco:
		return "El registro se corta de golpe, sin las líneas del apagado ordenado: " +
			"corte de luz, botón de apagado o reset forzado, un cuelgue total o un fallo de la fuente."
	}
	return ""
}

// kernelDeBoot averigua con qué núcleo arrancó esa sesión. Es lo que delata un
// problema que empezó justo al actualizar el kernel.
func kernelDeBoot(n int) string {
	salida, err := corre("journalctl", "-b", strconv.Itoa(n), "-k",
		"-g", "Linux version", "-n", "1", "-o", "json", "--no-pager")
	if err != nil {
		return ""
	}
	ents := parseaJournalJSON(salida)
	if len(ents) == 0 {
		return ""
	}
	m := regexp.MustCompile(`Linux version (\S+)`).FindStringSubmatch(ents[0].msg)
	if m == nil {
		return ""
	}
	return m[1]
}
