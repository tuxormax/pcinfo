package collector

import "fmt"

// INCIDENCIAS DE DISCO — lo que le ha PASADO al disco, no lo que el disco dice
// de sí mismo.
//
// ⭐ Por qué existe esto. Hasta la Rev 44 la salud de un disco salía solo del
// S.M.A.R.T., y eso deja fuera lo más revelador: los errores de lectura y
// escritura que el sistema ya registró, las veces que el disco se fue del bus y
// las veces que hubo que reparar su sistema de archivos. En macOS es peor
// todavía, porque **por USB no hay S.M.A.R.T. de ninguna manera** (ver
// [[pcinfo-bugs-macos]]): sin esto, un disco externo se queda sin ninguna
// información de salud aunque el sistema lleve horas apuntando sus fallos.
//
// Caso real que lo motivó (12-sep-2026, disco de 2 TB de tuxor): el registro del
// sistema tenía **154 000 líneas de error de E/S** sobre ese disco, 3 909
// sectores distintos que no se pudieron leer —**3 727 de ellos juntos, en un
// tramo de 1,2 GB**— y el disco contestando *HARDWARE ERROR / INTERNAL TARGET
// FAILURE*. Nada de eso aparecía en PCInfo, y es justo el dato que dice si el
// disco está dañado de verdad.

// IncidenciasDiscos es la respuesta de /discos/incidencias.
type IncidenciasDiscos struct {
	Disponible bool `json:"disponible"`
	// Motivo explica POR QUÉ no hay datos, cuando no los hay (plataforma sin
	// implementar, registro no accesible…). Nunca se deja vacío si Disponible
	// es false.
	Motivo string `json:"motivo"`
	// Fuente es de dónde salieron los datos, para que el usuario sepa a qué
	// registro mirar ("registro unificado de macOS", "journald", …).
	Fuente string            `json:"fuente"`
	Horas  int               `json:"horas"`
	Discos []IncidenciaDisco `json:"discos"`
}

// IncidenciaDisco es el historial de UN disco en la ventana consultada.
type IncidenciaDisco struct {
	// Device es "/dev/disk4" (o el nombre nativo en otras plataformas).
	Device string `json:"device"`
	// Etiqueta es como nombra el sistema a ese disco en el registro; sirve para
	// que el usuario reconozca las líneas si va a mirarlo él mismo.
	Etiqueta string `json:"etiqueta"`

	// Conectado dice si ese disco sigue puesto AHORA. Un disco que ya no está
	// aparece igual: su historial es justo lo que hace falta cuando un disco se
	// acaba de ir. La GUI lo marca para que no se confunda con uno presente.
	Conectado bool `json:"conectado"`

	ErroresES     int `json:"erroresES"`     // líneas de error de E/S
	SectoresMalos int `json:"sectoresMalos"` // posiciones DISTINTAS que fallaron
	Desconexiones int `json:"desconexiones"` // veces que el disco se fue del bus
	Reparaciones  int `json:"reparaciones"`  // veces que se reparó su sistema de archivos
	Arranques     int `json:"arranques"`     // veces que se le pidió algo estando dormido/parado

	// FalloInterno: el disco contestó "error de hardware / fallo interno". Es la
	// diferencia entre "no contestó" (cable, corriente) y "contestó que no pudo".
	FalloInterno bool `json:"falloInterno"`

	Primera string `json:"primera"` // primera incidencia de la ventana
	Ultima  string `json:"ultima"`  // última

	// Zonas son los tramos del disco donde se concentran los fallos. Que estén
	// CONCENTRADOS o dispersos es lo que distingue un disco con una zona dañada
	// de un disco que simplemente dejó de responder.
	Zonas []ZonaDanada `json:"zonas"`

	Veredicto string `json:"veredicto"`
	Notas     []Nota `json:"notas"`
}

// ZonaDanada es un tramo del disco con fallos de lectura agrupados.
type ZonaDanada struct {
	DesdeGB     float64 `json:"desdeGB"`
	HastaGB     float64 `json:"hastaGB"`
	Sectores    int     `json:"sectores"`    // posiciones distintas que fallaron ahí
	MBIlegibles float64 `json:"mbIlegibles"` // tamaño estimado que no se pudo leer
}

// redactaIncidencia escribe el veredicto y las notas de un disco, con el mismo
// criterio que la batería y la salud del disco: una frase que dice qué hacer y
// notas que traducen cada número.
func redactaIncidencia(in *IncidenciaDisco, tamBytes int64) {
	in.Notas = nil

	// El dato que más pesa: ¿hay una zona concentrada que no se puede leer?
	var peor ZonaDanada
	for _, z := range in.Zonas {
		if z.Sectores > peor.Sectores {
			peor = z
		}
	}

	if !in.Conectado {
		in.Notas = append(in.Notas, Nota{
			Level:  NotaInfo,
			Title:  "Este disco ya no está conectado",
			Detail: "Lo de abajo es lo que le pasó mientras estuvo puesto, según el registro del sistema.",
		})
	}

	switch {
	case peor.Sectores >= 100:
		in.Veredicto = fmt.Sprintf(
			"Este disco tiene una zona que NO se puede leer: unos %s alrededor del "+
				"GB %.0f. Eso es daño del disco en sí, no del índice de archivos, y no "+
				"se repara: lo que hubiera guardado ahí ya no se puede recuperar desde "+
				"aquí. Copia lo que aún se lea y no le confíes nada más.",
			tamañoEnPalabras(peor.MBIlegibles), peor.DesdeGB)
	case in.SectoresMalos > 0 && in.FalloInterno:
		in.Veredicto = "El disco contestó «fallo interno» en algunas lecturas. Son " +
			"pocas y sueltas: vigílalo, repite la revisión en unos días y ten las " +
			"copias al día."
	case in.Desconexiones > 0 && in.ErroresES > 0:
		in.Veredicto = "El disco dejó de responder y se fue del bus. Eso apunta al " +
			"cable o a la corriente que recibe, no necesariamente al disco. Pruébalo " +
			"con otro cable y enchufado directo al equipo."
	case in.Desconexiones > 0:
		in.Veredicto = "El disco se desconectó solo, sin dar errores de lectura. " +
			"Cable, conector o corriente: en un disco externo es lo primero que hay " +
			"que descartar."
	case in.ErroresES > 0:
		in.Veredicto = "Hubo errores de lectura o escritura, pero el disco no se fue " +
			"del bus ni dijo tener un fallo interno. Repite la revisión en unos días."
	default:
		in.Veredicto = "Sin incidencias registradas en esta ventana de tiempo."
	}

	if in.ErroresES > 0 {
		in.Notas = append(in.Notas, Nota{
			Level: nivelPorErrores(in.ErroresES),
			Title: "Errores de lectura y escritura",
			Detail: fmt.Sprintf(
				"El sistema anotó %s error(es) al leer o escribir en este disco, sobre "+
					"%s posición(es) distinta(s). Cada uno se reintentó varias veces antes "+
					"de darse por vencido. Un disco sano no produce ninguno.",
				miles(in.ErroresES), miles(in.SectoresMalos)),
		})
	}

	for _, z := range in.Zonas {
		if z.Sectores < 10 {
			continue // ruido suelto: no merece una nota propia
		}
		in.Notas = append(in.Notas, Nota{
			Level: NotaGrave,
			Title: fmt.Sprintf("Zona dañada en el GB %.0f", z.DesdeGB),
			Detail: fmt.Sprintf(
				"Entre el GB %.1f y el GB %.1f del disco hay %s posición(es) que no "+
					"respondieron: unos %s que no se pueden leer. Cuando los fallos se "+
					"agrupan así en un tramo, es el disco el que está dañado; si estuvieran "+
					"sueltos por todas partes, apuntaría al cable.",
				z.DesdeGB, z.HastaGB, miles(z.Sectores), tamañoEnPalabras(z.MBIlegibles)),
		})
	}

	if in.FalloInterno {
		in.Notas = append(in.Notas, Nota{
			Level: NotaGrave,
			Title: "El disco dijo que falló por dentro",
			Detail: "En esos errores el disco no se quedó callado: contestó «error de " +
				"hardware, fallo interno». Es una diferencia importante — un cable malo " +
				"o poca corriente hacen que el disco NO contteste; aquí contestó para " +
				"decir que no pudo.",
		})
	}

	if in.Arranques > 0 {
		in.Notas = append(in.Notas, Nota{
			Level: NotaAviso,
			Title: "Se le pidió algo mientras arrancaba",
			Detail: fmt.Sprintf(
				"%d vez/veces el disco contestó que todavía estaba arrancando el motor. "+
					"En un disco externo eso suele ser falta de corriente: se para solo y "+
					"tiene que volver a arrancar.", in.Arranques),
		})
	}

	if in.Desconexiones > 0 {
		in.Notas = append(in.Notas, Nota{
			Level: NotaGrave,
			Title: "Se fue del bus sin avisar",
			Detail: fmt.Sprintf(
				"El disco desapareció %d vez/veces sin que nadie lo expulsara. Cada una "+
					"de esas puede dejar a medias lo que se estuviera escribiendo, y es de "+
					"donde sale el daño del sistema de archivos. Cable, conector, hub o "+
					"corriente.", in.Desconexiones),
		})
	}

	if in.Reparaciones > 0 {
		in.Notas = append(in.Notas, Nota{
			Level: NotaAviso,
			Title: "Hubo que reparar su sistema de archivos",
			Detail: fmt.Sprintf(
				"El sistema tuvo que repararlo %d vez/veces. Eso se arregla —y se "+
					"arregló—, pero volverá a pasar mientras el disco siga desconectándose. "+
					"Si el disco se usa solo en este equipo, un formato con diario (journal) "+
					"aguanta mucho mejor estos cortes.", in.Reparaciones),
		})
	}

	if tamBytes > 0 && peor.Sectores >= 100 {
		in.Notas = append(in.Notas, Nota{
			Level: NotaInfo,
			Title: "Qué se puede hacer",
			Detail: "Lo primero y lo urgente es copiar lo que todavía se lea, empezando " +
				"por lo que no se puede volver a conseguir. Un disco con una zona dañada " +
				"no se repara; como mucho se puede seguir usando para cosas que no " +
				"importen, y nunca como única copia.",
		})
	}
}

// nivelPorErrores gradúa el aviso por cantidad: unos pocos errores pueden ser un
// cable; decenas de miles no.
func nivelPorErrores(n int) string {
	switch {
	case n >= 1000:
		return NotaGrave
	case n >= 10:
		return NotaAviso
	default:
		return NotaInfo
	}
}

// tamañoEnPalabras redondea megas a algo legible ("488 MB", "1,2 GB").
func tamañoEnPalabras(mb float64) string {
	if mb >= 1024 {
		return fmt.Sprintf("%.1f GB", mb/1024)
	}
	if mb >= 1 {
		return fmt.Sprintf("%.0f MB", mb)
	}
	return fmt.Sprintf("%.0f KB", mb*1024)
}
