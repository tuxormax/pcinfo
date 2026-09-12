package collector

import (
	"fmt"
	"runtime"
	"strings"
)

func runtimeEsWindows() bool { return runtime.GOOS == "windows" }

// Salud del disco EXPLICADA, con el mismo criterio que la de la batería: una
// frase que dice qué hacer y varias notas que traducen cada número técnico.
//
// Por qué aquí y no en la GUI: el texto tiene que ser IDÉNTICO en la pantalla y
// en el reporte que se guarda, y así se corrige en un solo sitio. Es la misma
// decisión que en bateria.go.
//
// Los problemas concretos (sectores reasignados, errores CRC, advertencia
// crítica NVMe…) ya los detecta evalDiskHealth en smart.go; aquí se envuelven
// junto con lo que hay que saber aunque el disco esté perfecto.

// motivoSinSalud dice POR QUÉ no hay datos de salud, que es lo único útil
// cuando faltan: sin esto el usuario ve "no se pudo" y no sabe si el problema es
// del disco, del permiso o del cable.
func motivoSinSalud() string {
	if !smartctlAvailable() {
		if runtimeEsWindows() {
			return "Falta la herramienta que le pregunta la salud a los discos " +
				"(smartctl). Vuelve a instalar PCInfo: viene incluida."
		}
		return "Falta la herramienta que le pregunta la salud a los discos. " +
			"Instálala con: sudo apt install smartmontools"
	}
	if !isElevated() {
		if runtimeEsWindows() {
			return "Para preguntarle la salud al disco hace falta permiso de " +
				"administrador. Usa el botón \"Reintentar como administrador\"."
		}
		return "Para preguntarle la salud al disco hace falta ejecutar PCInfo " +
			"como administrador (root)."
	}
	return "Este disco no contesta cuando se le pregunta por su salud. No " +
		"significa que esté mal: hay conexiones —algunos gabinetes USB, " +
		"controladoras RAID— que no dejan pasar la pregunta."
}

// interpretaDisco redacta el veredicto y las explicaciones de UN disco.
func interpretaDisco(d *DiskInfo) {
	d.Notes = nil

	switch {
	case d.Removable:
		d.Verdict = "Es una memoria extraíble (USB o tarjeta): este tipo de medio " +
			"no informa de su salud, así que no hay nada que revisar."
		return
	case !d.SmartAvailable:
		// macOS tiene sus propios motivos: los genéricos mandan usar `apt` o
		// ejecutar como root, y ninguna de las dos cosas aplica allí.
		// Impl en disco_salud_darwin.go; en el resto devuelve "".
		if m := motivoSinSaludDarwin(d); m != "" {
			d.Verdict = m
			return
		}
		d.Verdict = motivoSinSalud()
		return
	}

	vida := vidaRestante(d)

	switch d.HealthLevel {
	case "fail":
		d.Verdict = "Este disco está fallando. Haz una copia de seguridad AHORA y " +
			"cámbialo: puede dejar de funcionar cualquier día."
	case "warning":
		d.Verdict = "Este disco da señales de desgaste. Todavía funciona, pero " +
			"conviene tener las copias de seguridad al día y no confiarle nada único."
	default:
		if vida >= 0 && vida <= 20 {
			d.Verdict = "El disco no reporta averías, pero le queda poca vida útil: " +
				"ve pensando en cambiarlo."
		} else {
			d.Verdict = "El disco está sano."
		}
	}

	// 1. Vida útil (solo SSD/NVMe: a un disco mecánico no se le mide así).
	if vida >= 0 {
		nivel, cierre := NotaInfo, "Va sobrado."
		if vida <= 10 {
			nivel, cierre = NotaGrave, "Está al final: cámbialo antes de que empiece a dar problemas."
		} else if vida <= 30 {
			nivel, cierre = NotaAviso, "Ya se le nota el uso; no lo dejes para el último día."
		}
		d.Notes = append(d.Notes, Nota{
			Level: nivel,
			Title: "Cuánta vida le queda",
			Detail: fmt.Sprintf(
				"Las celdas de un disco de estado sólido se gastan cada vez que se "+
					"escribe en ellas, y el propio disco lleva la cuenta. A este le "+
					"queda el %d %% de su vida. %s", vida, cierre),
		})
	}

	// 2. Horas encendido: la edad real del disco, que casi nunca es la del equipo.
	if d.PowerOnHours > 0 {
		nivel, cierre := NotaInfo, "Le queda camino por delante."
		anios := float64(d.PowerOnHours) / 24 / 365
		if anios >= 5 {
			nivel, cierre = NotaAviso, "Ya pasó la vida típica de un disco; vigílalo aunque hoy esté bien."
		} else if anios >= 3 {
			cierre = "Está en la edad en la que conviene tener copias al día."
		}
		d.Notes = append(d.Notes, Nota{
			Level: nivel,
			Title: "Cuánto lleva funcionando",
			Detail: fmt.Sprintf(
				"Ha estado encendido %s horas: %s de funcionamiento seguido. Un disco "+
					"suele dar entre 3 y 5 años de uso normal. %s",
				miles(d.PowerOnHours), tiempoEnPalabras(d.PowerOnHours), cierre),
		})
	}

	// 3. Cuánto se ha escrito, medido en "veces que se ha llenado el disco": es
	//    lo único que da idea de si 35 TiB son muchos o pocos.
	if d.WrittenBytes > 0 {
		detalle := fmt.Sprintf("Desde que se estrenó se han escrito %s en él.",
			bytesEnPalabras(d.WrittenBytes))
		if d.SizeBytes > 0 {
			veces := d.WrittenBytes / d.SizeBytes
			detalle += fmt.Sprintf(" Es como haberlo llenado entero %d veces.", veces)
		}
		d.Notes = append(d.Notes, Nota{
			Level: NotaInfo, Title: "Cuánto se ha escrito en él", Detail: detalle,
		})
	}

	// 4. Sectores dañados: la señal más clara de que un disco se está muriendo.
	if d.ReallocatedSectors > 0 {
		d.Notes = append(d.Notes, Nota{
			Level: NotaAviso,
			Title: "Trozos dañados del disco",
			Detail: fmt.Sprintf(
				"El disco ha tenido que apartar %d trozo(s) estropeados y usar los de "+
					"repuesto que trae de fábrica. Que existan no es raro; que AUMENTEN "+
					"con el tiempo sí: vuelve a mirar este número en unas semanas.",
				d.ReallocatedSectors),
		})
	} else if d.SmartAvailable {
		d.Notes = append(d.Notes, Nota{
			Level: NotaInfo,
			Title: "Trozos dañados del disco",
			Detail: "Ninguno. Es la mejor señal de que el disco está entero: cuando " +
				"empiezan a aparecer, es el aviso de que se está muriendo.",
		})
	}

	// 5. Los problemas concretos que detectó el análisis SMART.
	for _, is := range d.Issues {
		nivel := NotaAviso
		if is.Severity == "fail" {
			nivel = NotaGrave
		}
		d.Notes = append(d.Notes, Nota{Level: nivel, Title: is.Title, Detail: is.Detail})
	}

	// 6. Qué hacer, cuando hay algo que hacer.
	if d.HealthLevel == "warning" || d.HealthLevel == "fail" {
		d.Notes = append(d.Notes, Nota{
			Level: NotaInfo,
			Title: "Qué se puede hacer",
			Detail: "Un disco dañado no se repara: se sustituye. Lo urgente es la " +
				"copia de seguridad —primero lo que no se puede volver a conseguir: " +
				"fotos, documentos, facturas—. Copia a otro disco o a la nube, y " +
				"comprueba que los archivos copiados se abren.",
		})
	}
}

// vidaRestante devuelve el porcentaje de vida que le queda a un SSD, o -1 si el
// disco no lo reporta (los mecánicos nunca lo hacen). El backend guarda la vida
// CONSUMIDA; lo que se enseña es lo que queda, que es como lo entiende todo el
// mundo.
func vidaRestante(d *DiskInfo) int {
	if d.LifePercentUsed < 0 {
		return -1
	}
	v := 100 - d.LifePercentUsed
	if v < 0 {
		v = 0
	}
	return v
}

// tiempoEnPalabras convierte horas encendido en algo que se entiende de un
// vistazo: "1 año y 4 meses", "8 meses", "20 días".
func tiempoEnPalabras(horas int) string {
	dias := horas / 24
	switch {
	case dias >= 365:
		anios := dias / 365
		meses := (dias % 365) / 30
		txt := fmt.Sprintf("%d año%s", anios, plural(anios))
		if meses > 0 {
			txt += fmt.Sprintf(" y %d mes%s", meses, pluralEs(meses))
		}
		return txt
	case dias >= 30:
		meses := dias / 30
		return fmt.Sprintf("%d mes%s", meses, pluralEs(meses))
	case dias >= 1:
		return fmt.Sprintf("%d día%s", dias, plural(dias))
	default:
		return fmt.Sprintf("%d hora%s", horas, plural(horas))
	}
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

func pluralEs(n int) string {
	if n == 1 {
		return ""
	}
	return "es"
}

// bytesEnPalabras da el tamaño en la unidad que toque, con coma decimal.
func bytesEnPalabras(b int64) string {
	const k = 1024.0
	unidades := []string{"bytes", "KiB", "MiB", "GiB", "TiB", "PiB"}
	v := float64(b)
	i := 0
	for v >= k && i < len(unidades)-1 {
		v /= k
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%d bytes", b)
	}
	return strings.Replace(fmt.Sprintf("%.1f", v), ".", ",", 1) + " " + unidades[i]
}
