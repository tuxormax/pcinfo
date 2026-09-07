//go:build linux

package collector

import "testing"

func TestHorarioTimer(t *testing.T) {
	casos := map[string]string{
		`{ OnCalendar=*-*-* 06:00:00 ; next_elapse=... }`: "Todos los días a las 06:00",
		`{ OnCalendar=Mon *-*-* 00:00:00 ; x }`:           "Cada lunes a las 00:00",
		`{ OnCalendar=Sun *-*-* 03:10:00 ; x }`:           "Cada domingo a las 03:10",
		`{ OnCalendar=*-*-* *:00:00 ; x }`:                "Cada hora en punto",
		`{ OnCalendar=daily ; x }`:                        "Todos los días a medianoche",
		// Lo que no encaja en un patrón conocido se muestra crudo antes que
		// traducirlo mal: "07..23:30:00" no es "a las 07:23".
		`{ OnCalendar=*-*-* 07..23:30:00 ; x }`: "*-*-* 07..23:30:00",
		``:                                      "Cuando llega su hora programada",
	}
	for entrada, quiero := range casos {
		if got := horarioTimer(entrada); got != quiero {
			t.Errorf("horarioTimer(%q) = %q; se esperaba %q", entrada, got, quiero)
		}
	}
}

func TestDescribeCron(t *testing.T) {
	casos := []struct {
		campos []string
		quiero string
	}{
		{[]string{"0", "20", "*", "*", "*"}, "Todos los días a las 20:00"},
		{[]string{"30", "3", "*", "*", "0"}, "Cada domingo a las 03:30"},
		{[]string{"5", "*", "*", "*", "*"}, "Cada hora, en el minuto 5"},
		{[]string{"0", "6", "1", "*", "*"}, "El día 1 de cada mes a las 06:00"},
		{[]string{"5-55/10", "*", "*", "*", "*"}, "5-55/10 * * * *"},
	}
	for _, c := range casos {
		if got := describeCron(c.campos); got != c.quiero {
			t.Errorf("describeCron(%v) = %q; se esperaba %q", c.campos, got, c.quiero)
		}
	}
}

// Preguntarle a systemctl por una unidad PLANTILLA hace que aborte y no
// conteste por NINGUNA de las demás: la lista entera de temporizadores salía
// vacía por culpa de una sola.
func TestEsPlantilla(t *testing.T) {
	if !esPlantilla("mdadm-last-resort@.timer") {
		t.Error("mdadm-last-resort@.timer es una plantilla y no se detectó")
	}
	if esPlantilla("apt-daily.timer") || esPlantilla("getty@tty1.service") {
		t.Error("una unidad normal (o una instancia concreta) no es plantilla")
	}
}

// Bautizar cada línea de cron con la primera palabra del comando dejaba una
// lista de tareas llamadas "test", "cd" y "[".
func TestNombreCrontab(t *testing.T) {
	casos := map[string]string{
		"/etc/crontab":                   "crontab del sistema",
		"/var/spool/cron/crontabs/tuxor": "crontab de tuxor",
		"/etc/cron.d/e2scrub_all":        "e2scrub_all",
	}
	for entrada, quiero := range casos {
		if got := nombreCrontab(entrada); got != quiero {
			t.Errorf("nombreCrontab(%q) = %q; se esperaba %q", entrada, got, quiero)
		}
	}
}

func TestParseHoraSystemd(t *testing.T) {
	if t1 := parseHoraSystemd("@1788697820"); t1.Unix() != 1788697820 {
		t.Errorf("formato unix mal leído: %v", t1)
	}
	// Con el formato de siempre, el día y la zona vienen en el idioma del
	// sistema; solo se aprovecha la parte ISO del centro.
	got := parseHoraSystemd("Sat 2026-09-05 12:30:08 CST").Format("2006-01-02 15:04:05")
	if got != "2026-09-05 12:30:08" {
		t.Errorf("formato con día y zona mal leído: %q", got)
	}
	for _, vacio := range []string{"", "n/a", "0"} {
		if !parseHoraSystemd(vacio).IsZero() {
			t.Errorf("%q debía quedar sin fecha", vacio)
		}
	}
}

func TestComandoDe(t *testing.T) {
	exec := `{ path=/usr/local/bin/pg_backup.sh ; argv[]=/usr/local/bin/pg_backup.sh apagado ; ignore_errors=no }`
	if got := comandoDe(exec); got != "/usr/local/bin/pg_backup.sh apagado" {
		t.Errorf("comandoDe = %q", got)
	}
}

// Un servicio enganchado al apagado tiene que decirlo con esas palabras: es el
// dato que explica por qué no corrió el día que el equipo no se apagó.
func TestDisparoDe(t *testing.T) {
	casos := []struct {
		props  map[string]string
		quiero string
	}{
		{map[string]string{"WantedBy": "shutdown.target reboot.target halt.target"},
			"Al apagar o reiniciar el equipo"},
		{map[string]string{"WantedBy": "multi-user.target"}, "Al arrancar el equipo"},
		{map[string]string{"WantedBy": "timers.target"}, "Cuando lo dispara su temporizador"},
		{map[string]string{"WantedBy": "", "UnitFileState": "static"},
			"Cuando otro servicio lo necesita"},
	}
	for _, c := range casos {
		if got := disparoDe(c.props); got != c.quiero {
			t.Errorf("disparoDe(%v) = %q; se esperaba %q", c.props, got, c.quiero)
		}
	}
}
