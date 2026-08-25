//go:build linux

package collector

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Análisis del fallo del kernel — equivalente en Linux de leer el .dmp
// ---------------------------------------------------------------------------
//
// En Windows el culpable de un pantallazo sale de las ESTRUCTURAS del volcado
// (lista de módulos, pila de llamadas, módulos descargándose). En Linux ese
// mismo material no vive en un archivo binario: el kernel lo IMPRIME al morir,
// y ese texto es lo que hay que leer. Da exactamente los mismos tres datos.
//
// De dónde se saca, en orden de fiabilidad:
//
//	/sys/fs/pstore, /var/lib/systemd/pstore  → el dmesg rescatado del fallo
//	    (ERST de la UEFI o ramoops). Es el único que sobrevive a un panic de
//	    verdad: cuando el kernel se detiene de golpe, journald ya no alcanza a
//	    escribir en el disco y el registro del fallo se pierde.
//	/var/crash/<fecha>/vmcore-dmesg.txt      → lo mismo, guardado por kdump.
//	journald alrededor de cada Oops          → sirve para los fallos NO fatales
//	    (Oops del que el sistema se recuperó, soft lockup, tarea colgada), que
//	    sí llegan a registrarse.
//
// Qué se lee de ese texto:
//
//	"Modules linked in: nvidia(PO) vboxdrv(O-) i915 [last unloaded: rtw88_pci]"
//	    Los paréntesis son las banderas que pone el propio kernel: O = ajeno al
//	    núcleo, P = propietario, E = sin firmar, F = cargado a la fuerza; y el
//	    estado, '-' = DESCARGÁNDOSE, '+' = cargándose. Un módulo SIN paréntesis
//	    viene del propio Linux: es lo que aquí hace de "driver de Microsoft" y
//	    por eso no se le señala en la tarjeta de controladores.
//	"RIP: 0010:nvidia_probe+0x2a/0x120 [nvidia]"
//	    La instrucción que falló. Si trae módulo, es PRUEBA de quién se estaba
//	    ejecutando: lo más fuerte que se puede saber de un fallo.
//	" ? nvidia_probe+0x2a/0x120 [nvidia]"   (bajo "Call Trace:")
//	    La pila de llamadas, igual que la del volcado de Windows.
//
// Espejo de: errores_windows.ps1 (Analiza-Dump + ranking de culpables).

// Tope de fallos que se analizan. Cada uno cuesta una consulta a journald.
const maxPanicos = 8

// Ventana alrededor de un Oops registrado en journald: el bloque completo lo
// imprime el kernel de golpe, en menos de un segundo.
const (
	panicAntes   = 3 * time.Second
	panicDespues = 25 * time.Second
)

// moduloCrash es un módulo tal y como lo listó el kernel al caer.
type moduloCrash struct {
	nombre      string
	flags       string // letras entre paréntesis: "PO", "OE+", "O-"
	terceros    bool   // ajeno al núcleo (O/P/E/F) → es el que se puede quitar
	descargando bool   // '-' = el kernel lo estaba descargando en ese instante
}

// bloqueCrash es UN fallo del kernel con su texto ya interpretado.
type bloqueCrash struct {
	fuente   string // cómo se llama la fuente en pantalla
	ruta     string // archivo del que salió (vacío si vino de journald)
	cuando   time.Time
	texto    string
	modulos  []moduloCrash
	ultDesc  []string // "[last unloaded: X]" — se acababa de descargar
	ripFn    string   // "nvidia_probe+0x2a/0x120"
	ripMod   string   // "nvidia"
	pila     []string // módulos en la pila, en orden de aparición
	vecesMod map[string]int
	pilaFn   []string // nombres de función de la pila (para la nota)
	taint    string
	comm     string
	hardware string
}

// conStructuras dice si el texto sirve para diagnosticar. Sin lista de módulos
// ni pila no hay nada que analizar y no se cuenta como fallo analizado (el
// equivalente del volcado que no trae estructuras en Windows).
func (b *bloqueCrash) conEstructuras() bool {
	return len(b.modulos) > 0 || len(b.pilaFn) > 0 || b.ripFn != ""
}

// infoModulo es lo que modinfo sabe del módulo: sirve para poder cambiarlo.
type infoModulo struct {
	nombre  string
	desc    string
	autor   string
	verMod  string
	ruta    string
	intree  bool // viene con el propio Linux
	hallado bool
}

var (
	reModsLinked = regexp.MustCompile(`Modules linked in:\s*(.*)$`)
	reModTok     = regexp.MustCompile(`^([A-Za-z0-9_\-]+)(?:\(([^)]*)\))?$`)
	reUltDesc    = regexp.MustCompile(`\[last unloaded:\s*([^\]]+)\]`)
	// Un marco de la pila: "func+0x2a/0x120" y, si es de un módulo, "[nombre]"
	// (los kernels nuevos añaden el id de compilación dentro del corchete).
	reMarco    = regexp.MustCompile(`(([\w.$]+)\+0x[0-9a-fA-F]+/0x[0-9a-fA-FxX]+)(?:\s*\[([A-Za-z0-9_\-]+)[^\]]*\])?`)
	reTaint    = regexp.MustCompile(`Tainted:\s+([A-Z ]+?)\s+\S*\d`)
	reComm     = regexp.MustCompile(`Comm:\s*(\S+)`)
	reHardware = regexp.MustCompile(`Hardware name:\s*(.+?)\s*$`)
)

// ---------------------------------------------------------------------------
// Parseo del texto del fallo
// ---------------------------------------------------------------------------

// parseaCrash lee el texto impreso por el kernel al caer y saca de él lo mismo
// que Windows saca del volcado: módulos cargados, quién se estaba ejecutando y
// quién se estaba descargando.
func parseaCrash(texto string) *bloqueCrash {
	b := &bloqueCrash{texto: texto, vecesMod: map[string]int{}}
	enPila := map[string]bool{}
	for _, linea := range strings.Split(texto, "\n") {
		l := limpiaPrefijoKernel(linea)
		if l == "" {
			continue
		}
		if m := reModsLinked.FindStringSubmatch(l); m != nil && len(b.modulos) == 0 {
			b.modulos, b.ultDesc = parseaListaModulos(m[1])
			continue
		}
		if b.taint == "" {
			if m := reTaint.FindStringSubmatch(l); m != nil {
				b.taint = strings.Join(strings.Fields(m[1]), " ")
			}
		}
		if b.comm == "" {
			if m := reComm.FindStringSubmatch(l); m != nil {
				b.comm = m[1]
			}
		}
		if b.hardware == "" {
			if m := reHardware.FindStringSubmatch(l); m != nil {
				b.hardware = m[1]
			}
		}
		// La instrucción que falló. "RIP:" en x86-64, "IP:" en kernels viejos,
		// "PC is at" en ARM.
		if b.ripFn == "" {
			if i := indiceEtiqueta(l, "RIP:", "IP:", "PC is at"); i >= 0 {
				if m := reMarco.FindStringSubmatch(l[i:]); m != nil {
					b.ripFn, b.ripMod = m[1], m[3]
				}
			}
		}
		// Marcos de la pila. Se recorre toda la línea: un mismo renglón puede
		// traer más de una función en los kernels que imprimen "? a+0x/0x b+0x/0x".
		for _, m := range reMarco.FindAllStringSubmatch(l, -1) {
			b.pilaFn = append(b.pilaFn, m[2])
			if m[3] == "" {
				continue
			}
			b.vecesMod[m[3]]++
			if !enPila[m[3]] {
				enPila[m[3]] = true
				b.pila = append(b.pila, m[3])
			}
		}
	}
	return b
}

// limpiaPrefijoKernel quita "<4>[  102.402970] " de las líneas de pstore y
// vmcore-dmesg (journald ya entrega el mensaje pelado).
func limpiaPrefijoKernel(l string) string {
	l = strings.TrimRight(l, "\r\n")
	if i := strings.Index(l, ">"); i > 0 && i <= 4 && strings.HasPrefix(l, "<") {
		l = l[i+1:]
	}
	l = strings.TrimLeft(l, " ")
	if strings.HasPrefix(l, "[") {
		// Solo si es la marca de tiempo del kernel: "[  102.402970]".
		if j := strings.Index(l, "]"); j > 0 && esMarcaTiempo(l[1:j]) {
			l = l[j+1:]
		}
	}
	// El prefijo del syslog clásico, por si el texto viene de /var/log.
	if i := strings.Index(l, "kernel: "); i >= 0 && i < 60 {
		l = l[i+len("kernel: "):]
	}
	return strings.TrimSpace(l)
}

func esMarcaTiempo(s string) bool {
	s = strings.TrimSpace(s)
	if s == "" {
		return false
	}
	if _, err := strconv.ParseFloat(s, 64); err != nil {
		return false
	}
	return true
}

func indiceEtiqueta(l string, etiquetas ...string) int {
	for _, e := range etiquetas {
		if i := strings.Index(l, e); i >= 0 {
			return i + len(e)
		}
	}
	return -1
}

// parseaListaModulos lee "nvidia(PO) vboxdrv(O-) i915 [last unloaded: rtw88]".
func parseaListaModulos(s string) ([]moduloCrash, []string) {
	var ult []string
	if m := reUltDesc.FindStringSubmatch(s); m != nil {
		for _, n := range strings.Split(m[1], ",") {
			if n = strings.TrimSpace(n); n != "" {
				ult = append(ult, n)
			}
		}
		s = reUltDesc.ReplaceAllString(s, " ")
	}
	var out []moduloCrash
	for _, tok := range strings.Fields(s) {
		m := reModTok.FindStringSubmatch(tok)
		if m == nil {
			continue
		}
		mc := moduloCrash{nombre: m[1], flags: m[2]}
		// Sin paréntesis = módulo del propio Linux, firmado y en marcha: el
		// kernel solo imprime banderas cuando hay algo que decir.
		mc.terceros = strings.ContainsAny(mc.flags, "OPEF")
		mc.descargando = strings.Contains(mc.flags, "-")
		out = append(out, mc)
	}
	return out, ult
}

// ---------------------------------------------------------------------------
// Quién es quién: modinfo
// ---------------------------------------------------------------------------

// analizadorPanico guarda el estado de UNA pasada: la caché de modinfo (para no
// preguntar dos veces por el mismo módulo) y el acumulado de culpables que
// cruza todos los fallos. No es global a propósito: /errores puede atenderse en
// paralelo y un mapa compartido sería una carrera de datos.
type analizadorPanico struct {
	modinfo string
	cache   map[string]infoModulo
	acum    map[string]*acumCulpable
	total   int
}

type acumCulpable struct {
	pila     int
	descarga int
}

func nuevoAnalizadorPanico() *analizadorPanico {
	return &analizadorPanico{
		modinfo: rutaModinfo(),
		cache:   map[string]infoModulo{},
		acum:    map[string]*acumCulpable{},
	}
}

// rutaModinfo busca el binario. OJO: en Debian/Ubuntu vive en /usr/sbin, que NO
// está en el PATH de un usuario normal — buscarlo solo con LookPath falla justo
// cuando PCInfo no corre como root.
func rutaModinfo() string {
	if r, err := exec.LookPath("modinfo"); err == nil {
		return r
	}
	for _, p := range []string{"/usr/sbin/modinfo", "/sbin/modinfo", "/usr/bin/modinfo", "/bin/modinfo"} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

func (a *analizadorPanico) info(nombre string) infoModulo {
	if nombre == "" {
		return infoModulo{}
	}
	if v, ok := a.cache[nombre]; ok {
		return v
	}
	inf := infoModulo{nombre: nombre}
	if a.modinfo != "" {
		if out, err := corre(a.modinfo, nombre); err == nil {
			inf.hallado = true
			for _, l := range strings.Split(out, "\n") {
				campo, valor, ok := strings.Cut(l, ":")
				if !ok {
					continue
				}
				valor = strings.TrimSpace(valor)
				switch strings.TrimSpace(campo) {
				case "description":
					inf.desc = valor
				case "author":
					if inf.autor == "" {
						inf.autor = valor
					}
				case "version":
					inf.verMod = valor
				case "filename":
					inf.ruta = valor
				case "intree":
					inf.intree = strings.EqualFold(valor, "Y")
				}
			}
		}
	}
	a.cache[nombre] = inf
	return inf
}

// esDelKernel es el equivalente de Es-DeMicrosoft: un módulo que viene con el
// propio Linux no se señala como controlador a cambiar. Manda la bandera del
// crash (es el dato del momento del fallo); modinfo solo decide cuando el
// módulo no aparecía en la lista (por ejemplo, si ya se había descargado).
func (a *analizadorPanico) esDelKernel(b *bloqueCrash, nombre string) bool {
	for _, m := range b.modulos {
		if m.nombre == nombre {
			return !m.terceros
		}
	}
	inf := a.info(nombre)
	if !inf.hallado {
		// Sin información no se acusa a nadie, igual que en Windows cuando no
		// se puede leer el archivo del driver.
		return true
	}
	return inf.intree
}

func (a *analizadorPanico) descripcion(nombre string) string {
	inf := a.info(nombre)
	partes := []string{}
	for _, p := range []string{inf.desc, inf.autor} {
		if p != "" {
			partes = append(partes, p)
		}
	}
	if inf.verMod != "" {
		partes = append(partes, "v"+inf.verMod)
	}
	if inf.ruta != "" {
		partes = append(partes, inf.ruta)
	}
	return strings.Join(partes, " · ")
}

func (a *analizadorPanico) anota(nombre, como string) {
	if a.acum[nombre] == nil {
		a.acum[nombre] = &acumCulpable{}
	}
	if como == "pila" {
		a.acum[nombre].pila++
	} else {
		a.acum[nombre].descarga++
	}
}

// ---------------------------------------------------------------------------
// Diagnóstico de UN fallo
// ---------------------------------------------------------------------------

type dictamenPanico struct {
	culpable    string
	info        string
	confianza   string
	sospechosos []string
	evidencia   []string
	nota        string
}

// analiza decide a quién se señala y POR QUÉ, en el mismo orden de fuerza que
// el análisis del volcado de Windows.
func (a *analizadorPanico) analiza(b *bloqueCrash) dictamenPanico {
	a.total++
	d := dictamenPanico{}

	// Terceros que estaban en la pila, en orden de aparición (el de más arriba
	// primero, que es el que estaba ejecutándose).
	var pilaTerceros []string
	for _, m := range b.pila {
		if !a.esDelKernel(b, m) {
			pilaTerceros = append(pilaTerceros, m)
			a.anota(m, "pila")
		}
	}
	// Descargándose: la bandera '-' del propio kernel y el "[last unloaded:]".
	var descargando []string
	for _, m := range b.modulos {
		if m.descargando && m.terceros {
			descargando = append(descargando, m.nombre)
			a.anota(m.nombre, "descarga")
		}
	}
	for _, n := range b.ultDesc {
		if !a.esDelKernel(b, n) {
			descargando = append(descargando, n)
			a.anota(n, "descarga")
		}
	}

	// Terceros cargados: sospechosos cuando no se puede probar nada.
	var cargadosTerceros []string
	for _, m := range b.modulos {
		if m.terceros {
			cargadosTerceros = append(cargadosTerceros, m.nombre)
		}
	}

	señala := func(nombre, confianza string, porque ...string) {
		d.culpable = nombre
		d.info = a.descripcion(nombre)
		d.confianza = confianza
		d.evidencia = append(d.evidencia, porque...)
	}

	switch {
	// --- Prueba 1: el fallo ocurrió DENTRO de un módulo ajeno al núcleo ------
	case b.ripMod != "" && !a.esDelKernel(b, b.ripMod):
		señala(b.ripMod, "alta",
			"El fallo ocurrió DENTRO de '"+b.ripMod+"' (instrucción "+b.ripFn+
				"): su código se estaba ejecutando en el instante exacto en que el kernel se detuvo.")

	// --- Prueba 2: un módulo ajeno al núcleo estaba en la pila de llamadas ---
	case len(pilaTerceros) > 0:
		n := pilaTerceros[0]
		señala(n, "alta",
			"'"+n+"' aparece "+vecesTexto(b.vecesMod[n])+" en la pila de llamadas del fallo: "+
				"su código se estaba ejecutando cuando el kernel cayó.")

	// --- Prueba 3: se estaba descargando ------------------------------------
	// Es el clásico "se descargó dejando enganches vivos" (un temporizador, una
	// interrupción) y la siguiente operación salta a memoria que ya no es de
	// nadie. Patrón fuerte, pero el registro NO prueba que la dirección que
	// falló fuera suya: por eso es media y no alta.
	case len(descargando) > 0:
		n := descargando[0]
		señala(n, "media",
			"El kernel estaba DESCARGANDO el módulo '"+n+"' cuando ocurrió el fallo. "+
				"Un módulo que se descarga dejando trabajo pendiente es una causa clásica, "+
				"aunque este registro no prueba que la dirección que falló fuera suya.")

	// --- Sin terceros: se dice la verdad, que también es un dato -------------
	default:
		if mod := primerModuloKernel(b); mod != "" {
			// El RIP o la pila SÍ nombran un módulo, pero es del propio Linux.
			// Se nombra igual (es una prueba, no una sospecha), avisando de que
			// no es algo que se pueda desinstalar.
			señala(mod, "alta",
				"El fallo ocurrió dentro de '"+mod+"', que forma parte del propio Linux: "+
					"no es un controlador de terceros que se pueda quitar. "+
					"Actualiza el kernel; si se repite, sospecha del hardware (RAM, disco o temperatura).")
		} else {
			d.confianza = "baja"
			d.nota = "En la pila de llamadas de este fallo no interviene ningún módulo: solo funciones " +
				"del propio núcleo (" + resumePila(b.pilaFn) + "). No se puede señalar a un controlador con este registro."
		}
		if len(cargadosTerceros) > 0 {
			d.sospechosos = cargadosTerceros
			d.evidencia = append(d.evidencia,
				"Ninguno estaba en la pila. Se listan por ser módulos ajenos al núcleo que estaban "+
					"cargados al caer, que es una coincidencia, NO una prueba.")
		}
	}

	if d.culpable != "" {
		// Los otros sospechosos, empezando por el señalado (la GUI y el reporte
		// se saltan el primero, igual que en Windows).
		d.sospechosos = append([]string{d.culpable}, quitaDe(cargadosTerceros, d.culpable)...)
	}
	if b.taint != "" && strings.ContainsAny(b.taint, "OPE") {
		d.evidencia = append(d.evidencia,
			"El kernel estaba marcado como contaminado (Tainted: "+b.taint+"): había módulos ajenos "+
				"al núcleo cargados"+listaCorta(cargadosTerceros)+".")
	}
	for i, s := range d.sospechosos {
		inf := a.info(s)
		det := []string{}
		if inf.autor != "" {
			det = append(det, inf.autor)
		}
		if inf.verMod != "" {
			det = append(det, "v"+inf.verMod)
		}
		if len(det) > 0 {
			d.sospechosos[i] = s + " (" + strings.Join(det, ", ") + ")"
		}
	}
	if len(d.sospechosos) > 10 {
		d.sospechosos = d.sospechosos[:10]
	}
	return d
}

// primerModuloKernel devuelve el módulo del propio Linux que el fallo nombra
// (el del RIP, o el primero de la pila).
func primerModuloKernel(b *bloqueCrash) string {
	if b.ripMod != "" {
		return b.ripMod
	}
	if len(b.pila) > 0 {
		return b.pila[0]
	}
	return ""
}

func quitaDe(lista []string, quitar string) []string {
	out := []string{}
	for _, s := range lista {
		if s != quitar {
			out = append(out, s)
		}
	}
	return out
}

func listaCorta(l []string) string {
	if len(l) == 0 {
		return ""
	}
	if len(l) > 6 {
		l = l[:6]
	}
	return " (" + strings.Join(l, ", ") + ")"
}

func vecesTexto(n int) string {
	if n <= 1 {
		return "1 vez"
	}
	return strconv.Itoa(n) + " veces"
}

func resumePila(fns []string) string {
	if len(fns) == 0 {
		return "vacía"
	}
	if len(fns) > 6 {
		fns = fns[:6]
	}
	return strings.Join(fns, " → ")
}

// ---------------------------------------------------------------------------
// Ranking cruzando TODOS los fallos
// ---------------------------------------------------------------------------

// ranking arma la lista de controladores señalados. Solo entran los ajenos al
// núcleo: la tarjeta responde a "¿qué controlador cambio?", y un módulo del
// propio Linux no se desinstala.
func (a *analizadorPanico) ranking() []Culprit {
	out := []Culprit{}
	for nombre, ac := range a.acum {
		inf := a.info(nombre)
		if inf.hallado && inf.intree {
			continue
		}
		como := []string{}
		if ac.pila > 0 {
			como = append(como, "ejecutándose en "+strconv.Itoa(ac.pila)+" de "+strconv.Itoa(a.total))
		}
		if ac.descarga > 0 {
			como = append(como, "descargándose en "+strconv.Itoa(ac.descarga)+" de "+strconv.Itoa(a.total))
		}
		out = append(out, Culprit{
			Driver:    nombre,
			Device:    inf.desc,
			Vendor:    inf.autor,
			Version:   inf.verMod,
			Path:      inf.ruta,
			InStack:   ac.pila,
			Unloading: ac.descarga,
			Total:     a.total,
			Why:       strings.Join(como, " y "),
		})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].InStack != out[j].InStack {
			return out[i].InStack > out[j].InStack
		}
		if out[i].Unloading != out[j].Unloading {
			return out[i].Unloading > out[j].Unloading
		}
		return out[i].Driver < out[j].Driver
	})
	if len(out) > 10 {
		out = out[:10]
	}
	return out
}

// ---------------------------------------------------------------------------
// Fuentes: pstore, kdump y journald
// ---------------------------------------------------------------------------

// Dónde quedan en disco los registros del fallo. Son variables y no constantes
// solo para poder probarlas contra un directorio de mentira: sin esto la única
// forma de comprobar la lectura sería provocar un panic de verdad.
var (
	dirPstore        = "/sys/fs/pstore"
	dirPstoreSystemd = "/var/lib/systemd/pstore"
	dirCrash         = "/var/crash"
)

// bloquesGuardados busca los registros del fallo que quedaron EN DISCO. Son los
// únicos que sobreviven a un panic real, así que van primero.
func bloquesGuardados() []*bloqueCrash {
	out := []*bloqueCrash{}
	añade := func(ruta, fuente string) {
		st, err := os.Stat(ruta)
		if err != nil || st.IsDir() || st.Size() == 0 {
			return
		}
		datos, err := os.ReadFile(ruta)
		if err != nil {
			warn("panic "+ruta, err)
			return
		}
		b := parseaCrash(string(datos))
		b.ruta, b.fuente, b.cuando = ruta, fuente, st.ModTime()
		out = append(out, b)
	}

	// 1) pstore vivo: /sys/fs/pstore/dmesg-efi-123, dmesg-ramoops-0…
	if ents, err := os.ReadDir(dirPstore); err == nil {
		for _, e := range ents {
			if strings.HasPrefix(e.Name(), "dmesg-") {
				añade(filepath.Join(dirPstore, e.Name()), "pstore (registro rescatado del fallo)")
			}
		}
	}
	// 2) pstore archivado por systemd-pstore (vacía /sys/fs/pstore al arrancar).
	filepath.WalkDir(dirPstoreSystemd, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if strings.HasPrefix(d.Name(), "dmesg") {
			añade(p, "pstore archivado por systemd (registro rescatado del fallo)")
		}
		return nil
	})
	// 3) kdump: /var/crash/<fecha>/vmcore-dmesg.txt (y el dmesg.<fecha> viejo).
	if ents, err := os.ReadDir(dirCrash); err == nil {
		for _, e := range ents {
			if !e.IsDir() {
				continue
			}
			dir := filepath.Join(dirCrash, e.Name())
			sub, err := os.ReadDir(dir)
			if err != nil {
				continue
			}
			for _, f := range sub {
				n := f.Name()
				if n == "vmcore-dmesg.txt" || strings.HasPrefix(n, "dmesg") {
					añade(filepath.Join(dir, n), "kdump (volcado del kernel en "+dir+")")
				}
			}
		}
	}
	return out
}

// bloqueJournal reconstruye el texto del Oops alrededor de un instante. Hace
// falta porque journald guarda CADA renglón como una entrada distinta: la línea
// "Modules linked in:" y la pila viven en entradas separadas de la del "Oops:",
// y encima con prioridades distintas, así que el barrido normal no las trae.
func bloqueJournal(cuando time.Time) *bloqueCrash {
	desde := cuando.Add(-panicAntes).Format("2006-01-02 15:04:05")
	hasta := cuando.Add(panicDespues).Format("2006-01-02 15:04:05")
	out, err := corre("journalctl", "-k", "--no-pager", "-o", "cat", "--since", desde, "--until", hasta)
	if err != nil {
		warn("journalctl bloque panic", err)
		return nil
	}
	b := parseaCrash(out)
	b.cuando = cuando
	b.fuente = "journald (registro del kernel)"
	return b
}

// ---------------------------------------------------------------------------
// Enganche con el reporte
// ---------------------------------------------------------------------------

// instantesPanico devuelve CUÁNDO cayó el kernel, una vez por caída. Un solo
// Oops imprime varias líneas que casan con el catálogo ("BUG: unable to
// handle…", "Oops: 0000…", "Kernel panic - not syncing…"), así que las que
// caen en el mismo minuto son la misma caída y se cuentan una sola vez.
func instantesPanico(ents []entradaLog) []time.Time {
	var t []time.Time
	for _, e := range ents {
		if r := clasifica(e.texto()); r != nil && r.kind == KindBSOD {
			t = append(t, e.when)
		}
	}
	sort.Slice(t, func(i, j int) bool { return t[i].After(t[j]) })
	out := []time.Time{}
	for _, x := range t {
		if len(out) > 0 && out[len(out)-1].Sub(x) < time.Minute {
			continue
		}
		out = append(out, x)
	}
	return out
}

// analizaPanicos es el punto de entrada: enriquece los fallos del kernel que ya
// están en el reporte, añade los que solo existen en disco (pstore/kdump) y
// arma la tarjeta de controladores señalados cruzándolos todos.
//
// panicos son las entradas CRUDAS del journal que casaron con una regla de
// fallo del kernel: hacen falta sin agrupar porque cada caída es un fallo
// distinto que hay que analizar por separado, igual que cada .dmp en Windows.
func analizaPanicos(rep *ErrorsReport, panicos []time.Time) {
	bloques := bloquesGuardados()
	// Los de journald, del más reciente al más viejo y sin pasarse del tope.
	sort.Slice(panicos, func(i, j int) bool { return panicos[i].After(panicos[j]) })
	for _, t := range panicos {
		if len(bloques) >= maxPanicos {
			break
		}
		if b := bloqueJournal(t); b != nil && b.conEstructuras() {
			bloques = append(bloques, b)
		}
	}
	if len(bloques) == 0 {
		return
	}

	a := nuevoAnalizadorPanico()
	for _, b := range bloques {
		if !b.conEstructuras() {
			continue
		}
		d := a.analiza(b)
		aplicaDictamen(rep, b, d)
	}
	if a.total == 0 {
		return
	}
	// Los registros del fallo también son "volcados": son los archivos que hay
	// que llevarse para analizar el equipo en otro lado.
	for _, b := range bloques {
		if b.ruta == "" {
			continue
		}
		if st, err := os.Stat(b.ruta); err == nil && !yaEstaElVolcado(rep.Dumps, b.ruta) {
			rep.Dumps = append(rep.Dumps, DumpFile{
				Path: b.ruta, When: fechaLocal(st.ModTime()), SizeBytes: st.Size(),
			})
		}
	}
	rep.Culprits = a.ranking()
	rep.DumpsAnalyzed = a.total
	etiqueta := "fallos del kernel analizados"
	if a.total == 1 {
		etiqueta = "fallo del kernel analizado"
	}
	rep.AnalyzedLabel = strconv.Itoa(a.total) + " " + etiqueta
	rep.CulpritsNote = []string{
		"Cruzando todos los fallos del kernel encontrados.",
		"Estar en la pila de llamadas prueba que su código se estaba ejecutando.",
		"Estar descargándose es un patrón fuerte, pero indirecto.",
	}
}

// aplicaDictamen cuelga el análisis del fallo que corresponde: si ya hay un
// pantallazo en la lista a menos de dos minutos, se enriquece ese; si no (caso
// típico del panic de verdad, que nunca llegó a journald) se añade uno nuevo.
func aplicaDictamen(rep *ErrorsReport, b *bloqueCrash, d dictamenPanico) {
	for i := range rep.Items {
		it := &rep.Items[i]
		if it.Kind != KindBSOD {
			continue
		}
		if !cercaEnTiempo(it.When, b.cuando) && !cercaEnTiempo(it.FirstWhen, b.cuando) {
			continue
		}
		if it.Culprit != "" && it.Confidence != "" {
			return // ya analizado por un registro mejor (pstore manda)
		}
		it.Culprit = d.culpable
		it.CulpritInfo = d.info
		it.Confidence = d.confianza
		it.Suspects = d.sospechosos
		it.Evidence = d.evidencia
		it.Detail = detalleCrash(b, d) + "\n" + it.Detail
		it.Fix = fixConCulpable(d.culpable, it.Fix)
		return
	}
	// Un bloque de journald SIEMPRE pertenece a un fallo que ya está en la
	// lista (de ahí salió). Si la fecha no casó es porque esa fila agrupa varias
	// caídas y solo guarda la primera y la última: se cuelga del primer
	// pantallazo sin analizar en vez de duplicar la fila.
	if b.ruta == "" {
		for i := range rep.Items {
			if rep.Items[i].Kind == KindBSOD && rep.Items[i].Confidence == "" {
				rep.Items[i].Culprit = d.culpable
				rep.Items[i].CulpritInfo = d.info
				rep.Items[i].Confidence = d.confianza
				rep.Items[i].Suspects = d.sospechosos
				rep.Items[i].Evidence = d.evidencia
				rep.Items[i].Detail = detalleCrash(b, d) + "\n" + rep.Items[i].Detail
				rep.Items[i].Fix = fixConCulpable(d.culpable, rep.Items[i].Fix)
				return
			}
		}
		return
	}

	// No estaba en la lista: es un fallo que solo sobrevivió en el disco.
	it := SystemError{
		ID:          "crash:" + b.ruta,
		When:        fechaLocal(b.cuando),
		Count:       1,
		Severity:    SevCritico,
		Kind:        KindBSOD,
		Title:       "Fallo grave del kernel rescatado del registro del propio fallo",
		Source:      b.fuente,
		Culprit:     d.culpable,
		CulpritInfo: d.info,
		Confidence:  d.confianza,
		Suspects:    d.sospechosos,
		Evidence:    d.evidencia,
		Cause: "El núcleo de Linux se detuvo y no alcanzó a escribir el fallo en el diario del sistema: " +
			"lo que se lee aquí es el registro que el equipo guardó aparte (pstore/kdump) justo al caer. " +
			"Casi siempre lo provoca un módulo/controlador defectuoso o memoria RAM dañada.",
		Fix: fixConCulpable(d.culpable,
			"Si no se puede señalar a nadie, prueba la RAM con memtest86+ y arranca con un kernel anterior desde GRUB."),
		Detail: detalleCrash(b, d),
	}
	rep.Items = append(rep.Items, it)
}

func yaEstaElVolcado(l []DumpFile, ruta string) bool {
	for _, d := range l {
		if d.Path == ruta {
			return true
		}
	}
	return false
}

func fixConCulpable(culpable, resto string) string {
	if culpable == "" {
		return resto
	}
	return "Empieza por el módulo '" + culpable + "': actualízalo (o reinstala su paquete DKMS), " +
		"o quítalo con 'sudo modprobe -r " + culpable + "' y comprueba si el fallo desaparece. " + resto
}

// cercaEnTiempo compara la fecha "2006-01-02 15:04:05" de un item con la del
// registro guardado, con dos minutos de margen: el reloj del pstore y el del
// diario no tienen por qué coincidir al segundo.
func cercaEnTiempo(fecha string, t time.Time) bool {
	if fecha == "" || t.IsZero() {
		return false
	}
	f, err := time.ParseInLocation("2006-01-02 15:04:05", fecha, time.Local)
	if err != nil {
		return false
	}
	d := f.Sub(t)
	if d < 0 {
		d = -d
	}
	return d <= 2*time.Minute
}

// detalleCrash arma el texto crudo que se muestra bajo el error, con lo que
// hace falta para verificar el diagnóstico a mano.
func detalleCrash(b *bloqueCrash, d dictamenPanico) string {
	var sb strings.Builder
	sb.WriteString("Fuente del análisis: " + b.fuente + "\n")
	if b.ruta != "" {
		sb.WriteString("Archivo: " + b.ruta + "\n")
	}
	if b.ripFn != "" {
		sb.WriteString("Instrucción que falló: " + b.ripFn)
		if b.ripMod != "" {
			sb.WriteString(" [" + b.ripMod + "]")
		}
		sb.WriteString("\n")
	}
	if b.comm != "" {
		sb.WriteString("Proceso en ejecución: " + b.comm + "\n")
	}
	if b.taint != "" {
		sb.WriteString("Estado del kernel (Tainted): " + b.taint + "\n")
	}
	if b.hardware != "" {
		sb.WriteString("Equipo: " + b.hardware + "\n")
	}
	if len(b.pilaFn) > 0 {
		sb.WriteString("Pila de llamadas: " + resumePila(b.pilaFn) + "\n")
	}
	if len(b.modulos) > 0 {
		sb.WriteString("Módulos cargados: " + strconv.Itoa(len(b.modulos)) + "\n")
	}
	if d.nota != "" {
		sb.WriteString(d.nota + "\n")
	}
	if b.ruta != "" {
		sb.WriteString("\n" + recorta(b.texto, 4000) + "\n")
	}
	return sb.String()
}
