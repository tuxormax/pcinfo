package collector

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const shaOK = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// El catálogo embebido debe compilar entero: ninguna fila insegura se cuela.
func TestCatalogoDriversWebEmbebido(t *testing.T) {
	var n int
	if c := compilaDriversWeb(driversWebEmbebidos); c == nil {
		t.Fatal("catalogo_drivers.json no es JSON válido")
	} else {
		n = len(c)
	}
	var crudo []DriverWeb
	if err := json.Unmarshal(driversWebEmbebidos, &crudo); err != nil {
		t.Fatal(err)
	}
	if n != len(crudo) {
		t.Fatalf("filas descartadas por inseguras o mal formadas: %d de %d sobrevivieron", n, len(crudo))
	}
}

func TestCompilaDriversWebDescartaLoInseguro(t *testing.T) {
	doc := `[
	 {"id":"bien","nombre":"A","buscarId":"VEN_1","url":"https://x/a.zip","sha256":"` + shaOK + `","tipo":"zip"},
	 {"id":"http","nombre":"B","buscarId":"VEN_1","url":"http://x/b.zip","sha256":"` + shaOK + `","tipo":"zip"},
	 {"id":"sinhash","nombre":"C","buscarId":"VEN_1","url":"https://x/c.zip","tipo":"zip"},
	 {"id":"hashcorto","nombre":"D","buscarId":"VEN_1","url":"https://x/d.zip","sha256":"abc","tipo":"zip"},
	 {"id":"tipo","nombre":"E","buscarId":"VEN_1","url":"https://x/e.bat","sha256":"` + shaOK + `","tipo":"bat"},
	 {"id":"regex","nombre":"F","buscarId":"(","url":"https://x/f.zip","sha256":"` + shaOK + `","tipo":"zip"}
	]`
	got := compilaDriversWeb([]byte(doc))
	if len(got) != 1 || got[0].ID != "bien" {
		t.Fatalf("solo debía sobrevivir «bien»: %+v", got)
	}
	if v := compilaDriversWeb([]byte("[]")); v == nil || len(v) != 0 {
		t.Fatal("un catálogo vacío es válido y debe dar lista vacía, no nil")
	}
	if compilaDriversWeb([]byte("no es json")) != nil {
		t.Fatal("JSON inválido debe dar nil")
	}
}

func TestCandidatosWebRespetaLoDejadoAPropósito(t *testing.T) {
	driversWebUnaVez.Do(func() {})
	driversWeb = compilaDriversWeb([]byte(`[
	 {"id":"rtl","nombre":"Realtek LAN","fabricante":"Realtek","buscarId":"VEN_10EC&DEV_8168","url":"https://x/a.zip","sha256":"` + shaOK + `","tipo":"zip"},
	 {"id":"conex","nombre":"Conexant","fabricante":"Conexant","buscarId":"VEN_14F1","url":"https://x/b.zip","sha256":"` + shaOK + `","tipo":"zip"}
	]`))
	pend := explicaPendientes([]DispositivoPendiente{
		{Nombre: "Ethernet", InstanceID: `PCI\VEN_10EC&DEV_8168\1`, HardwareID: `PCI\VEN_10EC&DEV_8168`, Codigo: 28},
		{Nombre: "Audio", InstanceID: `HDAUDIO\VEN_14F1&DEV_5051\1`, HardwareID: `HDAUDIO\VEN_14F1`, Codigo: 28},
		{Nombre: "Otro", InstanceID: `PCI\VEN_8086&DEV_1\1`, Codigo: 28},
	})
	got := candidatosWeb(pend, "HP Elite SFF 805 G9")
	if len(got) != 2 {
		t.Fatalf("esperaba 2 candidatos, hay %d: %+v", len(got), got)
	}
	por := map[string]CandidatoWeb{}
	for _, c := range got {
		por[c.ID] = c
	}
	// Ethernet Realtek 8168 es caso «generico» (a propósito): sale desmarcado.
	if por["rtl"].Recomendado || por["rtl"].Aviso == "" {
		t.Errorf("el Ethernet dejado a propósito debe salir no recomendado y con aviso: %+v", por["rtl"])
	}
	if por["conex"].Recomendado {
		t.Errorf("Conexant se deja genérico a propósito: no debe recomendarse: %+v", por["conex"])
	}
}

func TestBajaVerificado(t *testing.T) {
	cuerpo := []byte("contenido del controlador")
	h := sha256.Sum256(cuerpo)
	sha := hex.EncodeToString(h[:])
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/404") {
			http.NotFound(w, r)
			return
		}
		w.Write(cuerpo)
	}))
	defer srv.Close()
	previo := clienteWeb
	clienteWeb = srv.Client()
	defer func() { clienteWeb = previo }()

	dir := t.TempDir()
	ok := filepath.Join(dir, "ok.bin")
	if err := bajaVerificado(context.Background(), srv.URL+"/x", sha, ok); err != nil {
		t.Fatalf("descarga válida falló: %v", err)
	}
	if b, _ := os.ReadFile(ok); string(b) != string(cuerpo) {
		t.Fatal("el archivo descargado no es el servido")
	}

	mal := filepath.Join(dir, "mal.bin")
	if err := bajaVerificado(context.Background(), srv.URL+"/x", shaOK, mal); err == nil {
		t.Fatal("un hash distinto debía rechazarse")
	}
	if _, err := os.Stat(mal); err == nil {
		t.Fatal("un archivo con hash distinto debe borrarse")
	}
	if err := bajaVerificado(context.Background(), srv.URL+"/404", sha, filepath.Join(dir, "n")); err == nil {
		t.Fatal("un 404 debía fallar")
	}
	if err := bajaVerificado(context.Background(), "http://x/a", sha, filepath.Join(dir, "h")); err == nil {
		t.Fatal("un enlace http debía rechazarse")
	}
}

func TestCandidatosWebFiltraPorEquipo(t *testing.T) {
	driversWebUnaVez.Do(func() {})
	driversWeb = compilaDriversWeb([]byte(`[
	 {"id":"hp","nombre":"HP LAN","buscarId":"VEN_10EC&DEV_8168","equipo":"^HP .*805 G9","url":"https://x/a.exe","sha256":"` + shaOK + `","tipo":"exe"}
	]`))
	pend := []DispositivoPendiente{{Nombre: "Eth", InstanceID: `PCI\VEN_10EC&DEV_8168\1`, Codigo: 28}}
	if n := len(candidatosWeb(pend, "HP Elite SFF 805 G9")); n != 1 {
		t.Errorf("en el HP indicado debía salir, salió %d", n)
	}
	if n := len(candidatosWeb(pend, "Dell Latitude 5420")); n != 0 {
		t.Errorf("en otro equipo no debía salir, salió %d", n)
	}
	if n := len(candidatosWeb(pend, "")); n != 0 {
		t.Errorf("sin saber el equipo no debía salir, salió %d", n)
	}
}

func TestHerramientaDelFabricante(t *testing.T) {
	doc := `[
	 {"id":"hp","nombre":"HPIA","fabricante":"HP","equipo":"^HP","ejecuta":"C:\\x.exe","url":"https://x/a.exe","sha256":"` + shaOK + `","tipo":"exe"},
	 {"id":"sinequipo","nombre":"X","fabricante":"HP","ejecuta":"C:\\x.exe","url":"https://x/b.exe","sha256":"` + shaOK + `","tipo":"exe"},
	 {"id":"sinnada","nombre":"Y","fabricante":"HP","url":"https://x/c.exe","sha256":"` + shaOK + `","tipo":"exe"}
	]`
	got := compilaDriversWeb([]byte(doc))
	if len(got) != 1 || got[0].ID != "hp" {
		t.Fatalf("la herramienta exige equipo y una fila sin buscarId ni ejecuta se descarta: %+v", got)
	}
	driversWebUnaVez.Do(func() {})
	driversWeb = got
	// Sale con SOLO el equipo, sin ningún dispositivo pendiente.
	if n := len(candidatosWeb(nil, "HP ProBook 450")); n != 1 {
		t.Errorf("en un HP debía ofrecerse la herramienta, salieron %d", n)
	}
	if n := len(candidatosWeb(nil, "Dell Latitude")); n != 0 {
		t.Errorf("en un Dell no debía ofrecerse la de HP, salieron %d", n)
	}
}

func TestCarpetaDriversWebPorFabricante(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	if got := filepath.Base(carpetaDriversWeb("HP")); got != "HP" {
		t.Errorf("la subcarpeta debe ser el fabricante, fue %q", got)
	}
	if got := filepath.Base(carpetaDriversWeb(`a/b:c`)); strings.ContainsAny(got, `/:\`) {
		t.Errorf("el nombre de carpeta no puede llevar separadores: %q", got)
	}
}
