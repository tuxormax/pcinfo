package collector

import (
	"fmt"
	"runtime"
	"strings"

	"github.com/jaypipes/ghw"
)

// Módulo "Batería": el estado de salud de la batería del portátil, explicado en
// español y con palabras de todos los días.
//
// Contrato: GET /bateria → BatteryReport. Espejo en
// pcinfo/lib/models/bateria.dart.
//
// De dónde salen los datos:
//   - Windows: el informe de batería del propio sistema (powercfg
//     /batteryreport /xml) más WMI para el estado de este momento. Es
//     EXACTAMENTE lo que Windows enseña en su informe HTML, pero traducido:
//     ahí todo viene en inglés, en mWh y sin decir qué significa.
//   - Linux: /sys/class/power_supply (el kernel publica lo mismo salvo el
//     historial, que Windows guarda y Linux no).
//
// Decisión de diseño: el veredicto ("está en buen estado", "conviene
// cambiarla") y las explicaciones se arman AQUÍ, no en la GUI. Es el mismo
// criterio que la salud de los discos: así el texto es idéntico en la pantalla
// y en el reporte que se guarda, y se corrige en un solo sitio.

// Nivel de salud de la batería (campo HealthLevel) y de cada explicación.
const (
	SaludBien  = "good"
	SaludAviso = "warning"
	SaludMal   = "fail"
	NotaInfo   = "info"
	NotaAviso  = "warning"
	NotaGrave  = "fail"
)

// Estado de carga en este momento (campo State).
const (
	EstadoCargando    = "cargando"
	EstadoDescargando = "descargando"
	EstadoLlena       = "llena"
	EstadoConectada   = "conectada"
)

// BatteryReport es la respuesta de GET /bateria.
type BatteryReport struct {
	OS         string `json:"os"`
	Supported  bool   `json:"supported"` // ¿el sistema permite leer la batería?
	Available  bool   `json:"available"` // ¿se pudo leer algo?
	HasBattery bool   `json:"hasBattery"`
	Reason     string `json:"reason"`    // por qué no hay datos, o aviso
	Source     string `json:"source"`    // de dónde salieron, en español
	Generated  string `json:"generated"` // cuándo se leyó ("2026-08-20 09:46")

	// Estado de la corriente en este momento.
	OnAC      bool `json:"onAc"`
	OnACKnown bool `json:"onAcKnown"`

	// Equipment es el equipo tal como lo pide una tienda de repuestos ("Lenovo
	// YOGA 910-13IKB (80VF)"). Cuando la batería no publica su referencia, esto
	// más el voltaje y los Wh es lo único con lo que se puede comprar una nueva.
	Equipment string `json:"equipment"`

	Batteries []BatteryItem  `json:"batteries"`
	History   []BatteryPoint `json:"history"`

	// Estimaciones de duración, en minutos. 0 = el sistema no las tiene (hacen
	// falta varias descargas observadas para calcularlas).
	RuntimeFullMin int `json:"runtimeFullMin"` // con la carga completa de HOY
	RuntimeNowMin  int `json:"runtimeNowMin"`  // lo que queda ahora mismo

	// NO se publica cuánto duraba "cuando era nueva" aunque Windows lo calcule:
	// esa cifra sale de una capacidad de fábrica que el firmware a veces declara
	// mal, y además una batería de repuesto no tiene por qué traer la misma
	// capacidad. Prometer una duración que quizá nunca existió y que el recambio
	// no va a dar solo sirve para decepcionar. (Decisión de tuxor, 20-Ago-2026.)

	// Duración MÍNIMA: el equipo a tope (vídeo a pantalla completa, brillo alto,
	// procesador al máximo). La estimación del sistema sale de lo que el usuario
	// ha hecho HABITUALMENTE, así que se queda corta justo cuando más importa:
	// nadie se preocupa por la batería escribiendo un correo, sino en un vuelo
	// viendo una película. Ver calculaConsumo.
	RuntimeHeavyMin int `json:"runtimeHeavyMin"`
	WattsTypicalMW  int `json:"wattsTypicalMW"` // consumo habitual medido, en mW
	WattsHeavyMW    int `json:"wattsHeavyMW"`   // consumo supuesto a tope, en mW
}

// BatteryItem es UNA batería del equipo con su salud ya interpretada.
type BatteryItem struct {
	Name string `json:"name"` // como la llama el equipo (BASE-BAT)

	// Model es el dato con el que se COMPRA una batería nueva: la referencia de
	// la pieza (L15M4PC0, 45N1049…). No todos los portátiles la publican; cuando
	// falta hay que pedirla por el modelo del equipo más el voltaje y los Wh, que
	// es justo lo que enseña la ficha de repuesto de la GUI.
	Model         string `json:"model"`
	Manufacturer  string `json:"manufacturer"` // Simplo, LG, Panasonic…
	Serial        string `json:"serial"`
	Chemistry     string `json:"chemistry"`     // crudo: LiP, LION, NiMH…
	ChemistryText string `json:"chemistryText"` // "Polímero de litio"
	VoltageMV     int    `json:"voltageMV"`     // voltaje nominal, en mV

	DesignMWh    int `json:"designMWh"`    // lo que guardaba de fábrica
	FullMWh      int `json:"fullMWh"`      // lo que guarda hoy cargada al 100 %
	RemainingMWh int `json:"remainingMWh"` // lo que tiene en este momento

	ChargePercent int    `json:"chargePercent"` // carga actual; -1 desconocido
	CycleCount    int    `json:"cycleCount"`    // cargas completas; -1 desconocido
	State         string `json:"state"`         // ver constantes Estado*

	// Salud = cuánto de la capacidad de fábrica le queda.
	HealthPercent int    `json:"healthPercent"` // -1 si no se puede calcular
	HealthLevel   string `json:"healthLevel"`   // good | warning | fail
	Verdict       string `json:"verdict"`       // frase corta en español
	Notes         []Nota `json:"notes"`         // el porqué, en simple
}

// Nota es una explicación en palabras sencillas: qué se midió y qué significa
// para el usuario. La comparten la batería y los discos: las dos pestañas
// enseñan lo mismo —un dato técnico traducido— y con un solo tipo el texto se
// redacta igual en las dos.
type Nota struct {
	Level  string `json:"level"`  // info | warning | fail
	Title  string `json:"title"`  // de qué habla
	Detail string `json:"detail"` // qué significa, sin tecnicismos
}

// BatteryPoint es la capacidad de la batería en una semana concreta: con la
// serie completa se ve cómo ha ido bajando con el tiempo.
type BatteryPoint struct {
	Period        string `json:"period"` // "27/06/2026 – 04/07/2026"
	FullMWh       int    `json:"fullMWh"`
	DesignMWh     int    `json:"designMWh"`
	HealthPercent int    `json:"healthPercent"`
}

// CollectBattery arma el informe de la batería del equipo.
func CollectBattery() BatteryReport {
	rep := safe("bateria", collectBattery)
	if rep.OS == "" {
		rep.OS = runtime.GOOS
	}
	if rep.Batteries == nil {
		rep.Batteries = []BatteryItem{}
	}
	if rep.History == nil {
		rep.History = []BatteryPoint{}
	}
	rep.HasBattery = len(rep.Batteries) > 0
	for i := range rep.Batteries {
		interpretaBateria(&rep.Batteries[i])
	}
	for i := range rep.History {
		p := &rep.History[i]
		p.HealthPercent = porcentajeSalud(p.FullMWh, p.DesignMWh)
	}
	calculaConsumo(&rep)
	if rep.HasBattery && rep.Equipment == "" {
		rep.Equipment = safe("bateria-equipo", equipoComercial)
	}
	if rep.Supported && !rep.HasBattery && rep.Reason == "" {
		rep.Reason = "Este equipo no tiene batería: es de escritorio o la batería " +
			"está desconectada."
	}
	return rep
}

// equipoComercial devuelve el nombre con el que se busca un repuesto. El modelo
// de la PLACA no sirve para eso: en un portátil es un código interno
// (LNVNB161216). El nombre comercial vive en el producto del DMI, repartido
// entre Name ("80VF") y Version ("Lenovo YOGA 910-13IKB") según el fabricante.
func equipoComercial() string {
	p, err := ghw.Product()
	if err != nil || p == nil {
		warn("producto", err)
		return ""
	}
	nombre := cleanDMI(p.Version)
	codigo := cleanDMI(p.Name)
	marca := cleanDMI(p.Vendor)
	// Lenovo pone el nombre comercial en Version y el código en Name; casi todos
	// los demás al revés. Se elige el más descriptivo y el otro va de apoyo.
	if len(codigo) > len(nombre) {
		nombre, codigo = codigo, nombre
	}
	if nombre == "" {
		nombre = codigo
		codigo = ""
	}
	if nombre == "" {
		return marca
	}
	if marca != "" && !strings.Contains(strings.ToLower(nombre), strings.ToLower(marca)) {
		nombre = marca + " " + nombre
	}
	// El código solo se añade si dice algo: muchas placas de escritorio ponen
	// restos como "-CF" o "Default string" en el campo que sobra.
	codigo = strings.Trim(codigo, "- ")
	if len(codigo) >= 4 && !strings.EqualFold(codigo, nombre) {
		nombre += " (" + codigo + ")"
	}
	return nombre
}

// factorUsoIntenso: cuántas veces más gasta el equipo trabajando a tope que en
// el uso habitual del que salen las estimaciones del sistema. 2,5 es la relación
// típica en un portátil entre navegar/ofimática con la pantalla a media luz y
// vídeo a pantalla completa con el brillo al máximo y el procesador cargado.
//
// No es un dato medido —medirlo exigiría vaciar la batería a propósito—, pero un
// número prudente y explicado sirve mucho más que un único número optimista: la
// estimación del sistema hace creer que la batería dura 6 h y media cuando en
// una película da menos de 3.
const factorUsoIntenso = 5 // se divide entre 2 → 2,5

// calculaConsumo deduce el gasto del equipo a partir de la estimación del propio
// sistema y con él la duración mínima. Si no hay estimación (Linux, o un Windows
// que aún no ha visto suficientes descargas) no se inventa nada: los campos
// quedan en 0 y la GUI no enseña esa fila.
func calculaConsumo(rep *BatteryReport) {
	if len(rep.Batteries) == 0 {
		return
	}
	llena := rep.Batteries[0].FullMWh
	if llena <= 0 {
		return
	}
	if rep.WattsTypicalMW <= 0 && rep.RuntimeFullMin > 0 {
		rep.WattsTypicalMW = llena * 60 / rep.RuntimeFullMin
	}
	if rep.WattsTypicalMW <= 0 {
		return
	}
	rep.WattsHeavyMW = rep.WattsTypicalMW * factorUsoIntenso / 2
	if rep.WattsHeavyMW > 0 {
		rep.RuntimeHeavyMin = llena * 60 / rep.WattsHeavyMW
	}
}

// porcentajeSalud es la salud de la batería: cuánto de la capacidad de fábrica
// conserva. Devuelve -1 cuando falta algún dato para calcularla.
func porcentajeSalud(full, design int) int {
	if full <= 0 || design <= 0 {
		return -1
	}
	p := full * 100 / design
	// Algunas baterías nuevas reportan un poco MÁS de lo que dice la etiqueta.
	// Un 103 % confunde más de lo que informa.
	if p > 100 {
		p = 100
	}
	return p
}

// nombresGenericos son etiquetas de RANURA, no modelos: aparecen igual en
// millones de equipos y no sirven para pedir un repuesto.
var nombresGenericos = map[string]bool{
	"base-bat": true, "battery": true, "bateria": true, "batería": true,
	"primary": true, "main": true, "bat0": true, "bat1": true, "bat": true,
	"cmb1": true, "cmb0": true, "unknown": true, "desconocido": true,
}

func esNombreGenerico(s string) bool {
	return nombresGenericos[strings.ToLower(strings.TrimSpace(s))]
}

// interpretaBateria calcula la salud y redacta el veredicto y las explicaciones.
// Es lo único que ve el usuario, así que está escrito para alguien que no sabe
// qué es un mWh.
func interpretaBateria(b *BatteryItem) {
	b.ChemistryText = quimicaEnEspanol(b.Chemistry)
	if b.Model == "" && !esNombreGenerico(b.Name) {
		b.Model = b.Name
	}
	b.HealthPercent = porcentajeSalud(b.FullMWh, b.DesignMWh)

	switch {
	case b.HealthPercent < 0:
		b.HealthLevel = ""
		b.Verdict = "No se pudo calcular el desgaste: el equipo no informa la " +
			"capacidad de fábrica de la batería."
	case b.HealthPercent >= 90:
		b.HealthLevel = SaludBien
		b.Verdict = "La batería está como nueva."
	case b.HealthPercent >= 80:
		b.HealthLevel = SaludBien
		b.Verdict = "La batería está en buen estado."
	case b.HealthPercent >= 60:
		b.HealthLevel = SaludAviso
		b.Verdict = "La batería está desgastada: dura bastante menos que cuando era nueva."
	case b.HealthPercent >= 40:
		b.HealthLevel = SaludAviso
		b.Verdict = "La batería está muy desgastada: conviene ir pensando en cambiarla."
	default:
		b.HealthLevel = SaludMal
		b.Verdict = "La batería está al final de su vida: lo razonable es cambiarla."
	}

	b.Notes = nil
	if b.HealthPercent >= 0 {
		nivel := NotaInfo
		if b.HealthLevel == SaludAviso {
			nivel = NotaAviso
		} else if b.HealthLevel == SaludMal {
			nivel = NotaGrave
		}
		b.Notes = append(b.Notes, Nota{
			Level: nivel,
			Title: "Cuánta carga aguanta hoy",
			Detail: fmt.Sprintf(
				"Cuando era nueva, cargada al 100 %% guardaba %s. Hoy, también "+
					"al 100 %%, guarda %s: le queda el %d %% de su capacidad "+
					"original. %s",
				energiaEnPalabras(b.DesignMWh),
				energiaEnPalabras(b.FullMWh),
				b.HealthPercent,
				efectoPractico(b.HealthPercent)),
		})
	}

	switch {
	case b.CycleCount > 0:
		nivel, extra := NotaInfo, "Va bien de recorrido."
		if b.CycleCount >= 1000 {
			nivel, extra = NotaAviso, "Ya pasó la vida que el fabricante promete; a partir de aquí baja más rápido."
		} else if b.CycleCount >= 500 {
			nivel, extra = NotaAviso, "Está a mitad de camino de lo que suele aguantar."
		}
		b.Notes = append(b.Notes, Nota{
			Level: nivel,
			Title: "Cuántas veces se ha cargado",
			Detail: fmt.Sprintf(
				"Lleva %d cargas completas contadas. Una batería de portátil suele "+
					"aguantar entre 300 y 1000 antes de notarse gastada. %s",
				b.CycleCount, extra),
		})
	case b.CycleCount == 0:
		b.Notes = append(b.Notes, Nota{
			Level: NotaInfo,
			Title: "Cuántas veces se ha cargado",
			Detail: "Este equipo no lleva la cuenta de las cargas: muchos portátiles " +
				"no publican ese dato. No es un problema de la batería.",
		})
	}

	if b.ChargePercent >= 0 {
		b.Notes = append(b.Notes, Nota{
			Level: NotaInfo,
			Title: "Cómo está ahora mismo",
			Detail: fmt.Sprintf("Tiene el %d %% de carga y está %s.",
				b.ChargePercent, estadoEnPalabras(b.State)),
		})
	}

	if b.HealthLevel == SaludAviso || b.HealthLevel == SaludMal {
		b.Notes = append(b.Notes, Nota{
			Level: NotaInfo,
			Title: "Qué se puede hacer",
			Detail: "El desgaste de una batería no se repara: se cambia. Mientras " +
				"tanto ayuda no dejarla siempre al 100 % enchufada, evitar el calor y " +
				"no vaciarla del todo a menudo. Si el equipo se apaga de golpe sin " +
				"avisar, ya no es solo desgaste: cámbiala.",
		})
	}
}

// efectoPractico traduce el porcentaje de salud a lo que el usuario nota.
func efectoPractico(salud int) string {
	switch {
	case salud >= 90:
		return "En la práctica dura casi lo mismo que el primer día."
	case salud >= 80:
		return "En la práctica dura un poco menos que el primer día; es normal con el uso."
	case salud >= 60:
		return "En la práctica, de cada hora que duraba antes ahora da algo más de media."
	case salud >= 40:
		return "En la práctica dura menos de la mitad que cuando era nueva."
	default:
		return "En la práctica el equipo casi solo funciona enchufado."
	}
}

// energiaEnPalabras convierte los mWh del informe de Windows —que no le dicen
// nada a nadie— en los Wh que vienen escritos en la etiqueta de la batería. El
// número crudo en mWh se conserva en la ficha de datos, no en la explicación.
func energiaEnPalabras(mwh int) string {
	if mwh <= 0 {
		return "una cantidad que el equipo no informa"
	}
	return conDecimal(float64(mwh)/1000) + " Wh"
}

// conDecimal usa la coma decimal del español: "67,9", no "67.9".
func conDecimal(v float64) string {
	return strings.Replace(
		strings.TrimSuffix(fmt.Sprintf("%.1f", v), ".0"), ".", ",", 1)
}

// miles separa los miles con PUNTO, como se escribe en español (11.559). El
// informe de Windows usa la coma inglesa; aquí todo va traducido.
func miles(n int) string {
	s := fmt.Sprintf("%d", n)
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte('.')
		}
		b.WriteRune(c)
	}
	return b.String()
}

func estadoEnPalabras(estado string) string {
	switch estado {
	case EstadoCargando:
		return "cargándose"
	case EstadoDescargando:
		return "gastándose (el equipo va con batería)"
	case EstadoLlena:
		return "llena y enchufada"
	case EstadoConectada:
		return "enchufada a la corriente"
	default:
		return "en un estado que el equipo no precisa"
	}
}

// quimicaEnEspanol traduce el código de química de la batería. Windows y Linux
// usan abreviaturas distintas para lo mismo.
func quimicaEnEspanol(q string) string {
	switch strings.ToLower(strings.TrimSpace(q)) {
	case "":
		return ""
	case "lip", "lipo", "li-poly", "li-polymer", "lithium polymer", "lipoly":
		return "Polímero de litio"
	case "lion", "li-ion", "lithium ion", "lithium-ion":
		return "Iones de litio"
	case "life", "lifepo4":
		return "Litio-ferrofosfato"
	case "nimh", "nickel metal hydride":
		return "Níquel e hidruro metálico"
	case "nicd", "nickel cadmium":
		return "Níquel-cadmio"
	case "pbac", "lead acid":
		return "Plomo-ácido"
	case "znair", "zinc air":
		return "Zinc-aire"
	default:
		return q
	}
}
