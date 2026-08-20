//go:build windows

package collector

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

//go:embed bateria_windows.ps1
var scriptBateria []byte

// Generar el informe de batería de Windows tarda unos segundos (recorre meses de
// registro de energía). 90 s es holgado incluso en un equipo lento con disco
// mecánico.
const timeoutBateria = 90 * time.Second

// crudoBateria es el JSON que devuelve bateria_windows.ps1. Es un formato
// INTERNO entre el script y este archivo; el contrato con la GUI es
// BatteryReport (bateria.go).
type crudoBateria struct {
	Aviso     string         `json:"aviso"`
	Generado  string         `json:"generado"`
	Baterias  listaBaterias  `json:"baterias"`
	Historial listaHistorial `json:"historial"`

	Estimaciones struct {
		LlenaMin int `json:"llenaMin"`
	} `json:"estimaciones"`

	Vivo struct {
		Porcentaje    int    `json:"porcentaje"`
		Estado        string `json:"estado"`
		EnCA          bool   `json:"enCA"`
		EnCAConocido  bool   `json:"enCAConocido"`
		Minutos       int    `json:"minutos"`
		RestanteMWh   int    `json:"restanteMWh"`
		CiclosWmi     int    `json:"ciclosWmi"`
		DisenoWmi     int    `json:"disenoWmi"`
		LlenaWmi      int    `json:"llenaWmi"`
		VoltajeMV     int    `json:"voltajeMV"`
		QuimicaWmi    string `json:"quimicaWmi"`
		NombreWmi     string `json:"nombreWmi"`
		ModeloWmi     string `json:"modeloWmi"`
		FabricanteWmi string `json:"fabricanteWmi"`
		SerieWmi      string `json:"serieWmi"`
	} `json:"vivo"`
}

type bateriaCruda struct {
	ID         string `json:"id"`
	Fabricante string `json:"fabricante"`
	Serie      string `json:"serie"`
	Quimica    string `json:"quimica"`
	DisenoMWh  int    `json:"disenoMWh"`
	LlenaMWh   int    `json:"llenaMWh"`
	Ciclos     int    `json:"ciclos"`
}

type periodoCrudo struct {
	Inicio    string `json:"inicio"`
	Fin       string `json:"fin"`
	LlenaMWh  int    `json:"llenaMWh"`
	DisenoMWh int    `json:"disenoMWh"`
}

// listaBaterias y listaHistorial aceptan que el JSON traiga un objeto suelto
// donde se espera un arreglo. Motivo: ConvertTo-Json de PowerShell 5.1 colapsa
// las listas de UN solo elemento, y el caso normal —un portátil con una sola
// batería— es justo ése. Sin esto, el equipo típico fallaría al decodificar.
type listaBaterias []bateriaCruda

func (l *listaBaterias) UnmarshalJSON(b []byte) error {
	return unoOVarios(b, (*[]bateriaCruda)(l))
}

type listaHistorial []periodoCrudo

func (l *listaHistorial) UnmarshalJSON(b []byte) error {
	return unoOVarios(b, (*[]periodoCrudo)(l))
}

func unoOVarios[T any](b []byte, destino *[]T) error {
	t := bytes.TrimSpace(b)
	if len(t) == 0 || string(t) == "null" {
		return nil
	}
	if t[0] == '[' {
		return json.Unmarshal(t, destino)
	}
	var uno T
	if err := json.Unmarshal(t, &uno); err != nil {
		return err
	}
	*destino = []T{uno}
	return nil
}

func collectBattery() BatteryReport {
	rep := BatteryReport{
		OS:        "windows",
		Supported: true,
		Source:    "Informe de batería de Windows (powercfg) y WMI",
		Generated: time.Now().Format("2006-01-02 15:04"),
	}

	crudo, err := leeBateriaWindows()
	if err != nil {
		rep.Reason = "No se pudo leer la batería: " + err.Error()
		return rep
	}
	rep.Available = true
	if crudo.Generado != "" {
		rep.Generated = crudo.Generado
	}
	rep.Reason = strings.TrimSpace(crudo.Aviso)
	rep.OnAC = crudo.Vivo.EnCA
	rep.OnACKnown = crudo.Vivo.EnCAConocido
	rep.RuntimeFullMin = crudo.Estimaciones.LlenaMin
	rep.RuntimeNowMin = crudo.Vivo.Minutos

	for _, c := range crudo.Baterias {
		rep.Batteries = append(rep.Batteries, BatteryItem{
			Name:          limpiaTexto(c.ID),
			Manufacturer:  limpiaTexto(c.Fabricante),
			Serial:        limpiaTexto(c.Serie),
			Chemistry:     limpiaTexto(c.Quimica),
			DesignMWh:     c.DisenoMWh,
			FullMWh:       c.LlenaMWh,
			CycleCount:    c.Ciclos,
			ChargePercent: -1,
		})
	}

	// Si el informe de Windows no salió (o no listó ninguna batería) pero WMI sí
	// ve una, se arma con lo que hay: es preferible una ficha con la capacidad y
	// la carga a decirle al usuario que su portátil no tiene batería.
	if len(rep.Batteries) == 0 && (crudo.Vivo.DisenoWmi > 0 || crudo.Vivo.Porcentaje >= 0) {
		rep.Batteries = append(rep.Batteries, BatteryItem{
			Name:          limpiaTexto(crudo.Vivo.NombreWmi),
			Model:         limpiaTexto(crudo.Vivo.ModeloWmi),
			Manufacturer:  limpiaTexto(crudo.Vivo.FabricanteWmi),
			Serial:        limpiaTexto(crudo.Vivo.SerieWmi),
			Chemistry:     limpiaTexto(crudo.Vivo.QuimicaWmi),
			CycleCount:    -1,
			ChargePercent: -1,
		})
	}

	// La primera batería es la del equipo: se completa con el estado en vivo y
	// con lo que WMI sepa y falte en el informe.
	if len(rep.Batteries) > 0 {
		b := &rep.Batteries[0]
		b.ChargePercent = crudo.Vivo.Porcentaje
		b.State = crudo.Vivo.Estado
		b.RemainingMWh = crudo.Vivo.RestanteMWh
		if b.DesignMWh <= 0 {
			b.DesignMWh = crudo.Vivo.DisenoWmi
		}
		if b.FullMWh <= 0 {
			b.FullMWh = crudo.Vivo.LlenaWmi
		}
		if b.CycleCount <= 0 && crudo.Vivo.CiclosWmi > 0 {
			b.CycleCount = crudo.Vivo.CiclosWmi
		}
		if b.Chemistry == "" {
			b.Chemistry = limpiaTexto(crudo.Vivo.QuimicaWmi)
		}
		if b.Name == "" {
			b.Name = limpiaTexto(crudo.Vivo.NombreWmi)
		}
		if b.VoltageMV <= 0 {
			b.VoltageMV = crudo.Vivo.VoltajeMV
		}
		// El modelo con el que se compra el repuesto: primero la referencia que
		// da WMI, y si no la hay, el nombre del informe cuando no sea una
		// etiqueta genérica de ranura ("BASE-BAT", "Battery").
		if b.Model == "" {
			b.Model = limpiaTexto(crudo.Vivo.ModeloWmi)
		}
		if b.Model == "" && !esNombreGenerico(b.Name) {
			b.Model = b.Name
		}
		if b.Model == "" && !esNombreGenerico(crudo.Vivo.NombreWmi) {
			b.Model = limpiaTexto(crudo.Vivo.NombreWmi)
		}
		// El porcentaje sin capacidad restante se puede deducir, y al revés.
		if b.RemainingMWh <= 0 && b.ChargePercent > 0 && b.FullMWh > 0 {
			b.RemainingMWh = b.FullMWh * b.ChargePercent / 100
		}
	}
	return rep
}

// leeBateriaWindows ejecuta el script y decodifica su respuesta.
func leeBateriaWindows() (crudoBateria, error) {
	var crudo crudoBateria

	salida, err := os.CreateTemp("", "pcinfo-bateria-*.json")
	if err != nil {
		return crudo, err
	}
	salida.Close()
	defer os.Remove(salida.Name())

	if _, err := correPS("bateria", scriptBateria, timeoutBateria, "-Salida", salida.Name()); err != nil {
		return crudo, err
	}
	datos, err := os.ReadFile(salida.Name())
	if err != nil {
		return crudo, err
	}
	if len(datos) == 0 {
		return crudo, fmt.Errorf("el lector de batería no devolvió resultados")
	}
	datos = []byte(strings.TrimPrefix(string(datos), "\ufeff"))
	if err := json.Unmarshal(datos, &crudo); err != nil {
		return crudo, fmt.Errorf("respuesta ilegible: %w", err)
	}
	return crudo, nil
}
