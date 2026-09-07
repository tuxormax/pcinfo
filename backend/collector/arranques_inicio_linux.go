//go:build linux

package collector

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Programas que se lanzan al iniciar sesión (Linux). Salen de los archivos
// .desktop de autoarranque: los de /etc/xdg/autostart valen para todos los
// usuarios y los de ~/.config/autostart solo para el suyo.
//
// Lo que de verdad importa aquí no es la lista, sino la última columna: si el
// programa está corriendo AHORA. Un programa de autoarranque que no arrancó
// —porque nadie inició sesión, o porque el entorno gráfico se cayó al arrancar—
// no deja ni un error en ningún registro: simplemente no hizo su trabajo, y eso
// no se descubre hasta que se echa de menos lo que hacía.

func leeProgramasInicio() ([]StartupItem, string) {
	vivos := procesosVivos()
	out := []StartupItem{}

	carpetas := []struct{ ruta, alcance string }{
		{"/etc/xdg/autostart", "todos los usuarios"},
	}
	// El home de cada usuario del equipo. Se recorren todos (y no solo el del
	// usuario actual) porque el backend puede estar corriendo como root, y
	// entonces "su" carpeta sería /root y no la de la persona que usa el equipo.
	if homes, err := filepath.Glob("/home/*/.config/autostart"); err == nil {
		for _, h := range homes {
			usuario := filepath.Base(filepath.Dir(filepath.Dir(h)))
			carpetas = append(carpetas, struct{ ruta, alcance string }{h, "usuario " + usuario})
		}
	}
	if h, err := os.UserHomeDir(); err == nil && h != "" && !strings.HasPrefix(h, "/home/") {
		carpetas = append(carpetas, struct{ ruta, alcance string }{
			filepath.Join(h, ".config", "autostart"), "usuario " + filepath.Base(h)})
	}

	visto := map[string]bool{}
	for _, c := range carpetas {
		entradas, err := filepath.Glob(filepath.Join(c.ruta, "*.desktop"))
		if err != nil {
			continue
		}
		for _, f := range entradas {
			it := leeDesktop(f, c.alcance, vivos)
			if it.Name == "" {
				continue
			}
			// Un .desktop del usuario tapa al del sistema con el mismo nombre.
			clave := filepath.Base(f)
			if visto[clave] {
				continue
			}
			visto[clave] = true
			out = append(out, it)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Enabled != out[j].Enabled {
			return out[i].Enabled
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})

	nota := ""
	if len(vivos) == 0 {
		nota = "No se pudo comprobar qué programas están en ejecución, así que la columna " +
			"\"corriendo ahora\" puede salir vacía."
	}
	return out, nota
}

// leeDesktop saca de un archivo .desktop lo poco que hace falta: cómo se llama,
// qué ejecuta y si está desactivado. Solo se mira la sección [Desktop Entry].
func leeDesktop(ruta, alcance string, vivos map[string]bool) StartupItem {
	datos, err := os.ReadFile(ruta)
	if err != nil {
		return StartupItem{}
	}
	campos := map[string]string{}
	enEntrada := false
	for _, l := range strings.Split(string(datos), "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "[") {
			enEntrada = strings.EqualFold(l, "[Desktop Entry]")
			continue
		}
		if !enEntrada || l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		if k, v, ok := strings.Cut(l, "="); ok {
			campos[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	nombre := primerNoVacio(campos["Name[es]"], campos["Name"], filepath.Base(ruta))
	exec := campos["Exec"]
	activo := !strings.EqualFold(campos["Hidden"], "true") &&
		!strings.EqualFold(campos["X-GNOME-Autostart-enabled"], "false")

	it := StartupItem{
		Name:    nombre,
		Command: exec,
		Source:  ruta,
		Scope:   alcance,
		Enabled: activo,
	}
	if activo && exec != "" {
		it.Running = estaCorriendo(exec, vivos)
	}
	switch {
	case !activo:
		it.Note = "Está desactivado: no se lanza al iniciar sesión."
	case it.Running:
		it.Note = "Se lanzó y sigue en ejecución."
	default:
		// Sin juzgar: muchos programas de arranque hacen su tarea y se cierran
		// (un comprobador de actualizaciones, un ajuste del teclado), así que no
		// estar en ejecución no significa que hayan fallado. Lo que el dato
		// permite ver es lo contrario: que uno que DEBERÍA seguir vivo no está.
		it.Note = "No está en ejecución ahora mismo. Puede ser normal: hay programas de " +
			"arranque que hacen su trabajo y se cierran."
	}
	return it
}

func primerNoVacio(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

// Intérpretes: cuando el autoarranque los invoca, el nombre del proceso que
// aparece es el del intérprete, no el del programa. Se salta al siguiente
// argumento para comparar contra algo con sentido.
var interpretes = map[string]bool{
	"python": true, "python2": true, "python3": true, "bash": true, "sh": true,
	"dash": true, "perl": true, "ruby": true, "node": true, "env": true,
	"flatpak": true, "sudo": true, "nohup": true,
}

// estaCorriendo compara el ejecutable declarado en el .desktop contra los
// procesos vivos.
func estaCorriendo(exec string, vivos map[string]bool) bool {
	campos := strings.Fields(exec)
	for _, c := range campos {
		if strings.HasPrefix(c, "-") || strings.HasPrefix(c, "%") {
			continue
		}
		base := filepath.Base(strings.Trim(c, `"'`))
		if base == "" {
			continue
		}
		if interpretes[base] {
			continue // era el intérprete: sigue al siguiente argumento
		}
		if coincideProceso(base, vivos) {
			return true
		}
		// Un script se reconoce por su nombre aunque lo lance un intérprete.
		if i := strings.LastIndex(base, "."); i > 0 && coincideProceso(base[:i], vivos) {
			return true
		}
		return false // el primer argumento útil manda: no seguir con sus parámetros
	}
	return false
}

// coincideProceso admite el recorte del kernel: el nombre corto de un proceso
// (/proc/PID/comm) se queda en 15 caracteres, así que un ejecutable con nombre
// largo nunca casaría entero.
func coincideProceso(nombre string, vivos map[string]bool) bool {
	if vivos[nombre] {
		return true
	}
	if len(nombre) > 15 && vivos[nombre[:15]] {
		return true
	}
	return false
}

// procesosVivos devuelve los nombres de los procesos en ejecución, tanto el
// nombre corto del kernel como el del ejecutable de la línea de comando.
func procesosVivos() map[string]bool {
	out := map[string]bool{}
	entradas, err := os.ReadDir("/proc")
	if err != nil {
		return out
	}
	for _, e := range entradas {
		if !e.IsDir() || e.Name() == "" || e.Name()[0] < '0' || e.Name()[0] > '9' {
			continue
		}
		if b, err := os.ReadFile(filepath.Join("/proc", e.Name(), "comm")); err == nil {
			if n := strings.TrimSpace(string(b)); n != "" {
				out[n] = true
			}
		}
		if b, err := os.ReadFile(filepath.Join("/proc", e.Name(), "cmdline")); err == nil {
			partes := strings.Split(string(b), "\x00")
			for _, p := range partes {
				p = strings.TrimSpace(p)
				if p == "" || strings.HasPrefix(p, "-") {
					continue
				}
				base := filepath.Base(p)
				if base != "" && !interpretes[base] {
					out[base] = true
					break
				}
			}
		}
	}
	return out
}
