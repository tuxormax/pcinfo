package collector

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Parseo del registro del sistema para sacar las incidencias de cada disco.
// Sin etiqueta de plataforma a propósito: así se prueba desde Linux con la
// muestra real de testdata/darwin (log_incidencias_disco.txt).

// Las tres formas en las que macOS anota un error de E/S de disco:
//
//  1. (IOStorageFamily) disk4s2: I/O error.
//     — el resumen, con el dispositivo pero sin decir dónde falló.
//  2. (IOSCSIBlockCommandsDevice) [Tech]: I/O error [0xe00002ca] dir 0x1
//     lba 0x81bd5b00 count 0x100, retry 1 ...
//     — el detalle: QUÉ posición del disco falló y cuánto se pedía.
//  3. (IOSCSIArchitectureModelFamily) [Tech] I/O error! Opcode 0x28, ...
//     Sense Data 0x04, 0x44, 0x00
//     — lo que CONTESTÓ el disco (la clave de "sense"), que es lo que
//     distingue "no contestó" de "contestó que no pudo".
var (
	reESResumen = regexp.MustCompile(`\(IOStorageFamily\) (disk\d+)(?:s\d+)?: I/O error`)
	reESDetalle = regexp.MustCompile(`\[([^\]]+)\]: I/O error \[0x[0-9a-f]+\] dir 0x([0-9a-f]+) lba 0x([0-9a-f]+) count 0x([0-9a-f]+)`)
	reSense     = regexp.MustCompile(`\[([^\]]+)\] I/O error!.*Sense Data 0x([0-9a-f]+), 0x([0-9a-f]+), 0x([0-9a-f]+)`)
	reQuitado   = regexp.MustCompile(`removed disk, id = /dev/(disk\d+)\.`)
	// Una expulsión ORDENADA se anuncia antes: "ejected disk … ongoing" o
	// "unmounted disk … ongoing". Una desconexión de SORPRESA no avisa: llega el
	// "removed" a secas y el desmontaje viene después, si llega. Esa diferencia
	// es lo único que distingue "al usuario se le cayó el cable" de "el usuario
	// lo expulsó bien" — y también deja fuera las imágenes de disco (.dmg), que
	// siempre se expulsan en orden.
	reAnunciada = regexp.MustCompile(`(?:ejected|unmounted) disk, id = /dev/(disk\d+)(?:s\d+)?, ongoing`)
	reHora      = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})`)
)

const sectorBytes = 512

// hueco entre posiciones para considerar que empieza otra zona del disco. 256 MB
// es holgado: los fallos de una zona dañada caen muy juntos, y así no se parte
// una misma avería en diez trozos.
const huecoZona = 256 << 20 / sectorBytes

// AnalizaIncidencias convierte las líneas del registro en el historial de cada
// disco. [discos] sirve para emparejar: el registro nombra el disco de dos
// formas —el dispositivo (disk4) y la etiqueta que le puso el sistema ([Tech],
// que es el nombre del medio)—, y solo con la lista de discos se sabe que las
// dos son el mismo.
func AnalizaIncidencias(lineas []string, discos []DiskInfo) []IncidenciaDisco {
	// acumulador por dispositivo
	type acc struct {
		in     IncidenciaDisco
		lbas   map[uint64]uint64 // posición → sectores pedidos (el mayor visto)
		tamaño int64
	}
	porDisco := map[string]*acc{}
	// Dispositivos con una expulsión ordenada anunciada y aún sin su "removed".
	anunciada := map[string]bool{}

	nuevo := func(clave string) *acc {
		if a, ok := porDisco[clave]; ok {
			return a
		}
		a := &acc{lbas: map[uint64]uint64{}}
		if strings.HasPrefix(clave, "/dev/") {
			a.in.Device = clave
		} else {
			// Clave por etiqueta: el registro habla de un disco que ya NO está
			// conectado, así que no hay dispositivo que ponerle. Su historial
			// sigue valiendo —es justo el de un disco que se fue—, y se marca.
			a.in.Etiqueta = clave
		}
		for _, d := range discos {
			if d.Name == clave {
				a.tamaño = d.SizeBytes
				a.in.Conectado = true
				break
			}
		}
		porDisco[clave] = a
		return a
	}

	// dispositivo al que pertenece una etiqueta del registro ("Tech" →
	// /dev/disk4, porque el modelo de ese disco contiene "Tech").
	// claveDeEtiqueta devuelve con qué clave acumular una línea que solo trae la
	// etiqueta del sistema ("[Tech]"). Si esa etiqueta corresponde a un disco
	// conectado, se usa su dispositivo; si no, la etiqueta misma: el disco ya no
	// está, y perder su historial sería lo peor que se puede hacer justo con el
	// disco que acaba de dar problemas.
	claveDeEtiqueta := func(et string) string {
		et = strings.TrimSpace(et)
		if et == "" {
			return ""
		}
		bajo := strings.ToLower(et)
		for _, d := range discos {
			if d.Model != "" && strings.Contains(strings.ToLower(d.Model), bajo) {
				return d.Name
			}
		}
		return et
	}

	marcaHora := func(a *acc, linea string) {
		m := reHora.FindStringSubmatch(linea)
		if m == nil {
			return
		}
		if a.in.Primera == "" || m[1] < a.in.Primera {
			a.in.Primera = m[1]
		}
		if m[1] > a.in.Ultima {
			a.in.Ultima = m[1]
		}
	}

	for _, l := range lineas {
		switch {
		case reESResumen.MatchString(l):
			m := reESResumen.FindStringSubmatch(l)
			a := nuevo("/dev/" + m[1])
			a.in.ErroresES++
			marcaHora(a, l)

		case reESDetalle.MatchString(l):
			m := reESDetalle.FindStringSubmatch(l)
			clave := claveDeEtiqueta(m[1])
			if clave == "" {
				continue // sin etiqueta no se puede atribuir a nadie
			}
			a := nuevo(clave)
			a.in.Etiqueta = strings.TrimSpace(m[1])
			lba, err1 := strconv.ParseUint(m[3], 16, 64)
			cnt, err2 := strconv.ParseUint(m[4], 16, 64)
			if err1 != nil || err2 != nil {
				continue
			}
			if cnt == 0 {
				cnt = 1
			}
			if v, ok := a.lbas[lba]; !ok || cnt > v {
				a.lbas[lba] = cnt
			}
			marcaHora(a, l)

		case reSense.MatchString(l):
			m := reSense.FindStringSubmatch(l)
			clave := claveDeEtiqueta(m[1])
			if clave == "" {
				continue
			}
			a := nuevo(clave)
			a.in.Etiqueta = strings.TrimSpace(m[1])
			// Clave de sense 0x04 = HARDWARE ERROR (el disco dice que falló por
			// dentro). 0x02 = NOT READY, y con 0x04/0x01 significa que estaba
			// arrancando el motor.
			// ⚠️ Se compara el NÚMERO, no el texto: el registro escribe "0x04",
			// así que comparar contra "4" no casa nunca (ya pasó).
			senseClave, _ := strconv.ParseUint(m[2], 16, 8)
			asc, _ := strconv.ParseUint(m[3], 16, 8)
			switch senseClave {
			case 0x04:
				a.in.FalloInterno = true
			case 0x02:
				if asc == 0x04 {
					a.in.Arranques++
				}
			}
			marcaHora(a, l)

		case reAnunciada.MatchString(l):
			// Expulsión ordenada en marcha: el "removed" que venga después no
			// cuenta como desconexión.
			anunciada["/dev/"+reAnunciada.FindStringSubmatch(l)[1]] = true

		case reQuitado.MatchString(l):
			dev := "/dev/" + reQuitado.FindStringSubmatch(l)[1]
			if anunciada[dev] {
				anunciada[dev] = false // se consume: fue una expulsión en orden
				continue
			}
			a := nuevo(dev)
			a.in.Desconexiones++
			marcaHora(a, l)

			// ⚠️ Las reparaciones del sistema de archivos NO se cuentan aquí: la
			// línea "was repaired successfully" no dice de qué dispositivo es. Se
			// cuentan abajo, con la línea que sí lo trae.
		}
	}

	// Las reparaciones sí traen el dispositivo, pero en la línea ANTERIOR
	// ("repaired disk, id = /dev/disk4s2, ongoing"). Se recorre buscando ese par.
	reRepDisco := regexp.MustCompile(`repaired disk, id = /dev/(disk\d+)(?:s\d+)?, success`)
	for _, l := range lineas {
		if m := reRepDisco.FindStringSubmatch(l); m != nil {
			a := nuevo("/dev/" + m[1])
			a.in.Reparaciones++
			marcaHora(a, l)
		}
	}

	// ⭐ Un mismo disco llega por DOS caminos y hay que unirlos: el resumen del
	// núcleo nombra el dispositivo ("disk4: I/O error") y el detalle nombra la
	// etiqueta del medio ("[Tech]: … lba …"). Ninguna línea del registro trae las
	// dos cosas juntas —se comprobó—, así que si la etiqueta no corresponde a un
	// disco conectado se unen por SOLAPE DE TIEMPO: los dos mensajes se emiten
	// por el mismo fallo, en el mismo instante. Sin esto, el disco sale partido
	// en dos fichas y ninguna de las dos se entiende.
	for clave, a := range porDisco {
		if strings.HasPrefix(clave, "/dev/") || len(a.lbas) == 0 {
			continue
		}
		for otra, b := range porDisco {
			if !strings.HasPrefix(otra, "/dev/") || b.in.ErroresES == 0 {
				continue
			}
			if !seSolapan(a.in.Primera, a.in.Ultima, b.in.Primera, b.in.Ultima) {
				continue
			}
			// gana el dispositivo como identidad; se le suma el detalle
			b.in.Etiqueta = a.in.Etiqueta
			b.in.FalloInterno = b.in.FalloInterno || a.in.FalloInterno
			b.in.Arranques += a.in.Arranques
			for lba, cnt := range a.lbas {
				if v, ok := b.lbas[lba]; !ok || cnt > v {
					b.lbas[lba] = cnt
				}
			}
			if a.in.Primera < b.in.Primera {
				b.in.Primera = a.in.Primera
			}
			if a.in.Ultima > b.in.Ultima {
				b.in.Ultima = a.in.Ultima
			}
			delete(porDisco, clave)
			break
		}
	}

	// Cerrar: agrupar las posiciones fallidas en zonas y redactar.
	salida := make([]IncidenciaDisco, 0, len(porDisco))
	for _, a := range porDisco {
		// ⛔ Ruido fuera: una entrada cuyo ÚNICO rastro es haberse quitado, y que
		// además ya no está conectada, casi siempre es una imagen de disco (.dmg)
		// o una tarjeta que se sacó. Anunciarla como "un disco se desconectó
		// solo" sería alarmar por nada. Si hubo errores de lectura o
		// reparaciones, se informa aunque el disco ya no esté.
		if !a.in.Conectado && a.in.ErroresES == 0 && a.in.Reparaciones == 0 && len(a.lbas) == 0 {
			continue
		}
		a.in.SectoresMalos = len(a.lbas)
		a.in.Zonas = agrupaZonas(a.lbas)
		redactaIncidencia(&a.in, a.tamaño)
		salida = append(salida, a.in)
	}
	sort.Slice(salida, func(i, j int) bool { return salida[i].Device < salida[j].Device })
	return salida
}

// seSolapan dice si dos ventanas de tiempo se cruzan. Las horas son texto
// "2026-09-12 11:24:34", que en ese formato se ordena igual que la fecha.
func seSolapan(a1, a2, b1, b2 string) bool {
	if a1 == "" || b1 == "" {
		return false
	}
	return a1 <= b2 && b1 <= a2
}

// agrupaZonas junta las posiciones fallidas que están cerca unas de otras. Que
// los fallos estén AGRUPADOS o dispersos es el dato que distingue un disco con
// una zona dañada de un disco que se quedó sin responder.
func agrupaZonas(lbas map[uint64]uint64) []ZonaDanada {
	if len(lbas) == 0 {
		return nil
	}
	pos := make([]uint64, 0, len(lbas))
	for l := range lbas {
		pos = append(pos, l)
	}
	sort.Slice(pos, func(i, j int) bool { return pos[i] < pos[j] })

	zonas := []ZonaDanada{}
	ini, fin, n, sectores := pos[0], pos[0], 0, uint64(0)
	cierra := func() {
		zonas = append(zonas, ZonaDanada{
			DesdeGB:     float64(ini) * sectorBytes / 1e9,
			HastaGB:     float64(fin) * sectorBytes / 1e9,
			Sectores:    n,
			MBIlegibles: float64(sectores) * sectorBytes / (1 << 20),
		})
	}
	for _, p := range pos {
		if p-fin > huecoZona && n > 0 {
			cierra()
			ini, n, sectores = p, 0, 0
		}
		fin = p
		n++
		sectores += lbas[p]
	}
	cierra()

	// Primero la zona con más fallos: es la que importa.
	sort.Slice(zonas, func(i, j int) bool { return zonas[i].Sectores > zonas[j].Sectores })
	return zonas
}
