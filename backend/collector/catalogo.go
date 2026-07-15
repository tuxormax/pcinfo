package collector

import (
	_ "embed"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Catálogo de placas: especificaciones VERIFICADAS (sacadas de la hoja de datos
// del fabricante) para las placas cuyo firmware miente. Es la fuente de máxima
// confianza para las ranuras de RAM y la capacidad máxima; ver el orden de
// preferencia en aplicaCatalogo().
//
// Va embebido en el binario, así que funciona sin internet (el caso normal en
// un taller). Si hay internet se refresca desde el repo en segundo plano y se
// guarda en caché, de modo que las placas que se agreguen al catálogo lleguen a
// las instalaciones existentes sin reinstalar nada.

//go:embed placas.json
var placasEmbebidas []byte

// urlCatalogo es el catálogo publicado en el repo (rama main).
const urlCatalogo = "https://raw.githubusercontent.com/tuxormax/pcinfo/main/backend/collector/placas.json"

// PlacaSpec es una fila del catálogo. Ranuras y MaxGiB en 0 = dato desconocido
// (no se sobrescribe lo que dijo el firmware).
type PlacaSpec struct {
	Fabricante string `json:"fabricante"`
	Modelo     string `json:"modelo"`
	Ranuras    int    `json:"ranuras"`
	MaxGiB     int    `json:"maxGiB"`
	Fuente     string `json:"fuente"`
}

var (
	catalogoUnaVez sync.Once
	catalogo       map[string]PlacaSpec
)

// cargaCatalogo arma el índice: primero lo embebido, encima lo descargado (si
// hay caché válida) y dispara un refresco en segundo plano para la próxima vez.
func cargaCatalogo() {
	catalogo = map[string]PlacaSpec{}
	indexa(placasEmbebidas)

	if b, err := os.ReadFile(rutaCache()); err == nil {
		indexa(b) // la versión descargada pisa a la embebida
	}
	go refrescaCatalogo()
}

// indexa agrega las filas de un JSON al catálogo. Un JSON corrupto se ignora en
// silencio: el catálogo es una mejora, nunca un motivo de fallo.
func indexa(b []byte) {
	var placas []PlacaSpec
	if err := json.Unmarshal(b, &placas); err != nil {
		warn("catálogo de placas", err)
		return
	}
	for _, p := range placas {
		if k := clavePlaca(p.Fabricante, p.Modelo); k != "" {
			catalogo[k] = p
		}
	}
}

// clavePlaca normaliza fabricante+modelo para que coincidan sin importar cómo
// lo escriba el DMI: "Gigabyte Technology Co., Ltd." + "A520M K V2 (rev. 1.1)"
// y "GIGABYTE" + "A520M K V2" dan la misma clave.
func clavePlaca(fabricante, modelo string) string {
	f, m := normalizaPlaca(fabricante), normalizaPlaca(modelo)
	if f == "" || m == "" {
		return ""
	}
	return marcaCanonica(f) + "|" + m
}

// aliasMarca lista las marcas cuyo fabricante en el DMI empieza distinto a como
// se escribe corto (o que el DMI escribe de varias formas). Cada entrada mapea
// un PREFIJO ya normalizado (mayúsculas, sin puntuación) a la marca canónica.
// Solo hacen falta las marcas DIVERGENTES: las demás (Dell→DELL, Lenovo, Acer,
// Toshiba, Samsung, Apple, Intel, Microsoft, Huawei, Fujitsu, LG, Gigabyte,
// ASRock, Biostar…) ya coinciden por su primera palabra y usan el default.
// El prefijo debe ser específico: "MICRO STAR", NO "MICRO", o "Microsoft
// Corporation" (Surface) caería en MSI.
var aliasMarca = []struct{ prefijo, canonica string }{
	{"ASUS", "ASUS"},              // ASUSTeK COMPUTER INC.
	{"MICRO STAR", "MSI"},         // Micro-Star International Co., Ltd.
	{"MSI", "MSI"},                // algunas placas ya reportan "MSI"
	{"ELITEGROUP", "ECS"},         // Elitegroup Computer Systems
	{"HEWLETT", "HP"},             // Hewlett-Packard (equipos viejos; los nuevos dicen "HP")
	{"SUPER MICRO", "SUPERMICRO"}, // Super Micro Computer, Inc.
	{"HON HAI", "FOXCONN"},        // Hon Hai Precision = Foxconn
	{"TIMI", "XIAOMI"},            // los portátiles Xiaomi reportan "Timi"
}

// marcaCanonica reduce el fabricante a una marca única. El DMI escribe la misma
// marca de muchas formas ("ASUSTeK COMPUTER INC." vs el "ASUS" del catálogo,
// "Micro-Star International Co., Ltd." vs "MSI"). Sin esto la clave del firmware
// ("ASUSTEK") y la del catálogo ("ASUS") nunca coincidirían y esas filas jamás
// se aplicarían. Se aplica a AMBOS lados, así que la forma larga y la corta caen
// en la misma clave.
func marcaCanonica(f string) string {
	for _, a := range aliasMarca {
		if strings.HasPrefix(f, a.prefijo) {
			return a.canonica
		}
	}
	// Por defecto: la primera palabra (marca); el DMI le cuelga
	// "TECHNOLOGY CO LTD", "INC", "CORPORATION"…
	if marca := strings.Fields(f); len(marca) > 0 {
		return marca[0]
	}
	return f
}

// normalizaPlaca pasa a mayúsculas, quita la revisión de placa y la puntuación,
// y colapsa los espacios.
func normalizaPlaca(s string) string {
	s = strings.ToUpper(strings.TrimSpace(s))
	if i := strings.Index(s, "(REV"); i >= 0 { // "A520M K V2 (rev. 1.1)"
		s = s[:i]
	}
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteRune(' ')
		}
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

// buscaPlaca devuelve la ficha verificada de la placa, si está en el catálogo.
func buscaPlaca(fabricante, modelo string) (PlacaSpec, bool) {
	catalogoUnaVez.Do(cargaCatalogo)
	p, ok := catalogo[clavePlaca(fabricante, modelo)]
	return p, ok
}

// rutaCache es donde se guarda el catálogo descargado
// (~/.cache/pcinfo/placas.json en Linux, %LOCALAPPDATA%\pcinfo\ en Windows).
func rutaCache() string {
	dir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "pcinfo", "placas.json")
}

// refrescaCatalogo baja el catálogo del repo y lo guarda en caché para el
// próximo arranque. Best-effort: sin internet, con timeout o con un JSON
// inválido simplemente no hace nada — nunca bloquea ni ensucia la caché con
// basura (por eso valida el JSON antes de escribirlo).
func refrescaCatalogo() {
	ruta := rutaCache()
	if ruta == "" {
		return
	}
	cli := &http.Client{Timeout: 5 * time.Second}
	resp, err := cli.Get(urlCatalogo)
	if err != nil {
		return // sin internet: se sigue usando el catálogo embebido
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20)) // tope 8 MB
	if err != nil {
		return
	}
	var placas []PlacaSpec
	if err := json.Unmarshal(b, &placas); err != nil || len(placas) == 0 {
		return
	}
	if err := os.MkdirAll(filepath.Dir(ruta), 0o755); err != nil {
		return
	}
	_ = os.WriteFile(ruta, b, 0o644)
}
