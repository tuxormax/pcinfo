//go:build darwin

package collector

import (
	"context"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Incidencias de disco en macOS: salen del REGISTRO UNIFICADO del sistema
// (`log show`), que es donde el núcleo apunta cada error de lectura, cada
// desconexión y cada reparación del sistema de archivos.
//
// ⭐ En macOS esto no es un extra, es la ÚNICA fuente de salud para un disco
// USB: por ahí no hay S.M.A.R.T. de ninguna manera (ver disco_salud_darwin.go).
//
// ⚠️ La consulta cuesta: ~6 s para 24 horas en la Mac mini M4 (medido). Por eso
// va en su propio endpoint y la GUI la pide APARTE, cuando el usuario abre la
// ficha — nunca en el arranque.

const plazoRegistro = 60 * time.Second

// predicadoIncidencias filtra en el propio `log show`, que es lo que hace la
// consulta viable: sin filtro son cientos de miles de líneas de todo el sistema.
// ⚠️ Las líneas de expulsión ("ejected"/"unmounted") hacen falta aunque no sean
// incidencias: son las que permiten distinguir una expulsión ORDENADA de una
// desconexión de SORPRESA. Sin ellas, las imágenes de disco (.dmg) y cualquier
// expulsión normal se contarían como caídas.
const predicadoIncidencias = `(process == "kernel" AND eventMessage CONTAINS "I/O error") ` +
	`OR (process == "diskarbitrationd" AND (eventMessage CONTAINS "removed disk" ` +
	`OR eventMessage CONTAINS "ejected disk" OR eventMessage CONTAINS "unmounted disk" ` +
	`OR eventMessage CONTAINS "repaired disk"))`

func collectIncidenciasDarwin(horas int, discos []DiskInfo) IncidenciasDiscos {
	out := IncidenciasDiscos{
		Fuente: "registro unificado de macOS (log show)",
		Horas:  horas,
	}

	ctx, cancel := context.WithTimeout(context.Background(), plazoRegistro)
	defer cancel()
	cmd := exec.CommandContext(ctx, "log", "show",
		"--last", strconv.Itoa(horas)+"h",
		"--style", "compact",
		"--predicate", predicadoIncidencias)
	salida, err := cmd.Output()
	if err != nil {
		warn("log show", err)
		out.Motivo = "No se pudo leer el registro del sistema: " + err.Error()
		return out
	}

	out.Disponible = true
	out.Discos = AnalizaIncidencias(strings.Split(string(salida), "\n"), discos)
	return out
}
