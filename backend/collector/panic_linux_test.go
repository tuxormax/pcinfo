//go:build linux

package collector

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Los textos de abajo son fallos de kernel reales (recortados): así es como el
// kernel imprime un Oops en x86-64 y así llegan desde journald, pstore o kdump.

// Fallo DENTRO de un módulo de terceros: el caso fuerte, el que sí se puede
// diagnosticar. nvidia_drm aparece en la instrucción que falló y en la pila.
const crashNvidia = `[  102.402881] BUG: unable to handle page fault for address: ffffffffc0a4b000
[  102.402887] #PF: supervisor instruction fetch in kernel mode
[  102.402894] Oops: 0011 [#1] PREEMPT SMP NOPTI
[  102.402897] CPU: 4 PID: 2345 Comm: Xorg Tainted: G           OE      6.8.0-138-generic #138-Ubuntu
[  102.402901] Hardware name: LENOVO 80Q1/Lenovo Yoga 910, BIOS 4WCN45WW 03/22/2018
[  102.402903] RIP: 0010:nv_drm_master_set+0x2a/0x120 [nvidia_drm]
[  102.402908] Code: 0f 1f 44 00 00 55 48 89 e5 41 57 41 56 41 55
[  102.402910] RSP: 0018:ffffb1e2c0a4bd58 EFLAGS: 00010246
[  102.402926] Call Trace:
[  102.402928]  <TASK>
[  102.402930]  ? show_regs+0x6d/0x80
[  102.402934]  ? __die+0x24/0x80
[  102.402940]  ? nv_drm_master_set+0x2a/0x120 [nvidia_drm]
[  102.402950]  drm_new_set_master+0x88/0x1a0
[  102.402960]  </TASK>
[  102.402970] Modules linked in: nvidia_drm(PO) nvidia_modeset(PO) nvidia(PO) vboxdrv(O) snd_hda_intel i915 btrfs
[  102.402975] CR2: ffffffffc0a4b000
[  102.402977] ---[ end trace 0000000000000000 ]---`

// Nadie de terceros en la pila, pero el kernel estaba DESCARGANDO un módulo
// ajeno al núcleo: la marca "(O-)" la pone el propio kernel.
const crashDescargando = `<4>[   88.100000] BUG: kernel NULL pointer dereference, address: 0000000000000000
<4>[   88.100010] Oops: 0000 [#1] PREEMPT SMP NOPTI
<4>[   88.100020] CPU: 1 PID: 921 Comm: rmmod Tainted: G           OE      6.8.0-138-generic #138-Ubuntu
<4>[   88.100030] RIP: 0010:__kmalloc_node+0x1a/0x30
<4>[   88.100050] Call Trace:
<4>[   88.100055]  <TASK>
<4>[   88.100060]  ? page_fault_oops+0x99/0x1b0
<4>[   88.100070]  __run_timers+0x22b/0x2c0
<4>[   88.100080]  </TASK>
<4>[   88.100090] Modules linked in: rtw89_pci(O-) rtw89_core(O) snd_hda_intel i915 [last unloaded: v4l2loopback]`

// El fallo cae dentro de un módulo del PROPIO Linux (sin paréntesis): se puede
// nombrar, porque la instrucción es prueba, pero no es nada que desinstalar.
const crashIntree = `[   55.000000] Oops: 0000 [#1] SMP
[   55.000010] CPU: 0 PID: 300 Comm: kworker/0:2 Not tainted 6.8.0-138-generic #138-Ubuntu
[   55.000020] RIP: 0010:i915_gem_object_pin+0x4c/0x220 [i915]
[   55.000030] Call Trace:
[   55.000040]  ? i915_gem_object_pin+0x4c/0x220 [i915]
[   55.000050]  process_one_work+0x175/0x350
[   55.000060] Modules linked in: snd_hda_intel i915 btrfs`

// Ni módulos ni pila con módulos: PCInfo no señala a nadie y lo dice.
const crashSinNadie = `[   30.000000] watchdog: BUG: soft lockup - CPU#2 stuck for 26s! [kworker/2:1:88]
[   30.000010] CPU: 2 PID: 88 Comm: kworker/2:1 Not tainted 6.8.0-138-generic #138-Ubuntu
[   30.000020] RIP: 0010:native_queued_spin_lock_slowpath+0x1b0/0x2a0
[   30.000030] Call Trace:
[   30.000040]  _raw_spin_lock+0x25/0x30
[   30.000050]  ext4_do_update_inode+0x1f0/0x780
[   30.000060] Modules linked in: snd_hda_intel i915 ext4`

// analizadorDePrueba deja modinfo fuera: en una máquina de pruebas el binario
// contestaría cosas distintas según qué módulos tenga instalados y los tests
// dejarían de ser deterministas.
func analizadorDePrueba(conocidos map[string]infoModulo) *analizadorPanico {
	a := nuevoAnalizadorPanico()
	a.modinfo = ""
	for k, v := range conocidos {
		v.nombre = k
		a.cache[k] = v
	}
	return a
}

func TestParseaCrashLeeLoQueTraeElFallo(t *testing.T) {
	b := parseaCrash(crashNvidia)
	if b.ripMod != "nvidia_drm" || b.ripFn != "nv_drm_master_set+0x2a/0x120" {
		t.Fatalf("instrucción que falló mal leída: %q / %q", b.ripFn, b.ripMod)
	}
	if b.comm != "Xorg" {
		t.Errorf("proceso = %q", b.comm)
	}
	if b.taint != "G OE" {
		t.Errorf("tainted = %q", b.taint)
	}
	if !strings.Contains(b.hardware, "LENOVO") {
		t.Errorf("equipo = %q", b.hardware)
	}
	if len(b.modulos) != 7 {
		t.Fatalf("módulos = %d, esperados 7: %+v", len(b.modulos), b.modulos)
	}
	// Con paréntesis = ajeno al núcleo; sin paréntesis = del propio Linux.
	terceros := map[string]bool{}
	for _, m := range b.modulos {
		terceros[m.nombre] = m.terceros
	}
	for _, n := range []string{"nvidia_drm", "nvidia_modeset", "nvidia", "vboxdrv"} {
		if !terceros[n] {
			t.Errorf("%s debería ser de terceros", n)
		}
	}
	for _, n := range []string{"snd_hda_intel", "i915", "btrfs"} {
		if terceros[n] {
			t.Errorf("%s viene con el propio Linux, no es de terceros", n)
		}
	}
	if b.vecesMod["nvidia_drm"] != 2 {
		t.Errorf("nvidia_drm aparece %d veces, esperadas 2", b.vecesMod["nvidia_drm"])
	}
	if !b.conEstructuras() {
		t.Error("el bloque trae módulos y pila: debería servir para analizar")
	}
}

func TestParseaListaModulosDescargandoseYUltimoDescargado(t *testing.T) {
	b := parseaCrash(crashDescargando)
	var desc []string
	for _, m := range b.modulos {
		if m.descargando {
			desc = append(desc, m.nombre)
		}
	}
	if len(desc) != 1 || desc[0] != "rtw89_pci" {
		t.Fatalf("descargándose = %v, esperado [rtw89_pci]", desc)
	}
	if len(b.ultDesc) != 1 || b.ultDesc[0] != "v4l2loopback" {
		t.Fatalf("last unloaded = %v", b.ultDesc)
	}
	// El "[last unloaded: …]" no debe colarse como si fuera un módulo cargado.
	for _, m := range b.modulos {
		if m.nombre == "v4l2loopback" || m.nombre == "last" || m.nombre == "unloaded" {
			t.Errorf("basura en la lista de módulos: %q", m.nombre)
		}
	}
}

func TestAnalizaSenalaAlQueSeEstabaEjecutando(t *testing.T) {
	a := analizadorDePrueba(nil)
	d := a.analiza(parseaCrash(crashNvidia))
	if d.culpable != "nvidia_drm" {
		t.Fatalf("culpable = %q, esperado nvidia_drm", d.culpable)
	}
	if d.confianza != "alta" {
		t.Errorf("confianza = %q, esperada alta", d.confianza)
	}
	if len(d.evidencia) == 0 || !strings.Contains(d.evidencia[0], "DENTRO") {
		t.Fatalf("la evidencia debe decir que el fallo ocurrió dentro del módulo: %v", d.evidencia)
	}
	// El resto de módulos ajenos al núcleo quedan como sospechosos, sin acusar.
	if len(d.sospechosos) < 4 || !strings.HasPrefix(d.sospechosos[0], "nvidia_drm") {
		t.Errorf("sospechosos = %v", d.sospechosos)
	}
	if !contieneAlgo(d.evidencia, "Tainted") {
		t.Errorf("faltó decir que el kernel estaba contaminado: %v", d.evidencia)
	}
}

func TestAnalizaSenalaAlQueSeEstabaDescargando(t *testing.T) {
	a := analizadorDePrueba(nil)
	d := a.analiza(parseaCrash(crashDescargando))
	if d.culpable != "rtw89_pci" {
		t.Fatalf("culpable = %q, esperado rtw89_pci", d.culpable)
	}
	// Descargándose es un patrón fuerte pero indirecto: nunca "alta".
	if d.confianza != "media" {
		t.Errorf("confianza = %q, esperada media", d.confianza)
	}
	if !contieneAlgo(d.evidencia, "DESCARGANDO") {
		t.Errorf("evidencia = %v", d.evidencia)
	}
}

func TestAnalizaNombraAlModuloDelPropioLinuxSinAcusarlo(t *testing.T) {
	a := analizadorDePrueba(nil)
	d := a.analiza(parseaCrash(crashIntree))
	if d.culpable != "i915" {
		t.Fatalf("culpable = %q, esperado i915", d.culpable)
	}
	if !contieneAlgo(d.evidencia, "forma parte del propio Linux") {
		t.Errorf("hay que avisar de que no es un controlador que se pueda quitar: %v", d.evidencia)
	}
	// Y NO puede salir en la tarjeta de controladores a cambiar.
	if len(a.ranking()) != 0 {
		t.Errorf("un módulo del propio Linux no se señala como controlador a cambiar: %+v", a.ranking())
	}
}

func TestAnalizaNoInventaCulpableCuandoNoLoHay(t *testing.T) {
	a := analizadorDePrueba(nil)
	d := a.analiza(parseaCrash(crashSinNadie))
	if d.culpable != "" {
		t.Fatalf("no había ningún módulo en la pila; no se puede acusar a %q", d.culpable)
	}
	if d.confianza != "baja" {
		t.Errorf("confianza = %q", d.confianza)
	}
	if !strings.Contains(d.nota, "no interviene ningún módulo") {
		t.Errorf("nota = %q", d.nota)
	}
}

func TestRankingCruzaTodosLosFallos(t *testing.T) {
	a := analizadorDePrueba(map[string]infoModulo{
		"nvidia_drm": {hallado: true, desc: "NVIDIA DRM driver", autor: "NVIDIA Corporation", verMod: "550.107.02", ruta: "/lib/modules/6.8.0/updates/dkms/nvidia-drm.ko"},
	})
	a.analiza(parseaCrash(crashNvidia))
	a.analiza(parseaCrash(crashNvidia))
	a.analiza(parseaCrash(crashDescargando))

	r := a.ranking()
	if len(r) == 0 {
		t.Fatal("no salió ningún controlador señalado")
	}
	primero := r[0]
	if primero.Driver != "nvidia_drm" {
		t.Fatalf("el más señalado es %q", primero.Driver)
	}
	if primero.InStack != 2 || primero.Total != 3 {
		t.Errorf("inStack=%d total=%d, esperados 2 y 3", primero.InStack, primero.Total)
	}
	if primero.Device != "NVIDIA DRM driver" || primero.Version != "550.107.02" {
		t.Errorf("falta lo que hace falta para cambiarlo: %+v", primero)
	}
	if !strings.Contains(primero.Why, "ejecutándose en 2 de 3") {
		t.Errorf("why = %q", primero.Why)
	}
	// El que se estaba descargando también entra, pero por debajo.
	var visto bool
	for _, c := range r {
		if c.Driver == "rtw89_pci" {
			visto = true
			if c.Unloading != 1 || c.InStack != 0 {
				t.Errorf("rtw89_pci: %+v", c)
			}
		}
	}
	if !visto {
		t.Error("el módulo que se estaba descargando debería aparecer en la lista")
	}
}

func TestLimpiaPrefijoKernel(t *testing.T) {
	casos := map[string]string{
		"<4>[  102.402970] Modules linked in: i915": "Modules linked in: i915",
		"[   88.100090] Oops: 0000 [#1]":            "Oops: 0000 [#1]",
		"kernel: RIP: 0010:foo+0x1/0x2":             "RIP: 0010:foo+0x1/0x2",
		"Call Trace:":                               "Call Trace:",
		// Un corchete que NO es la marca de tiempo se respeta.
		"[last unloaded: x]": "[last unloaded: x]",
	}
	for entrada, esperado := range casos {
		if got := limpiaPrefijoKernel(entrada); got != esperado {
			t.Errorf("%q → %q, esperado %q", entrada, got, esperado)
		}
	}
}

func TestInstantesPanicoAgrupaLaMismaCaida(t *testing.T) {
	base := time.Date(2026, 8, 25, 10, 0, 0, 0, time.Local)
	ents := []entradaLog{
		{when: base, msg: "BUG: unable to handle page fault for address: ffffffffc0a4b000"},
		{when: base.Add(2 * time.Millisecond), msg: "Oops: 0011 [#1] PREEMPT SMP NOPTI"},
		{when: base.Add(5 * time.Millisecond), msg: "Kernel panic - not syncing: Fatal exception"},
		{when: base.Add(-48 * time.Hour), msg: "general protection fault: 0000 [#1] SMP"},
		{when: base.Add(-time.Hour), msg: "usb 1-2: device descriptor read/64, error -110"},
	}
	got := instantesPanico(ents)
	if len(got) != 2 {
		t.Fatalf("caídas detectadas = %d, esperadas 2: %v", len(got), got)
	}
	if !got[0].After(got[1]) {
		t.Error("la más reciente va primero")
	}
}

func TestAplicaDictamenCreaElFalloQueSoloEstaEnDisco(t *testing.T) {
	rep := &ErrorsReport{Items: []SystemError{}}
	b := parseaCrash(crashNvidia)
	b.ruta, b.fuente = "/sys/fs/pstore/dmesg-efi-166", "pstore (registro rescatado del fallo)"
	b.cuando = time.Date(2026, 8, 25, 9, 0, 0, 0, time.Local)
	a := analizadorDePrueba(nil)
	aplicaDictamen(rep, b, a.analiza(b))

	if len(rep.Items) != 1 {
		t.Fatalf("items = %d", len(rep.Items))
	}
	it := rep.Items[0]
	if it.Kind != KindBSOD || it.Culprit != "nvidia_drm" {
		t.Fatalf("%+v", it)
	}
	if !strings.Contains(it.Fix, "modprobe -r nvidia_drm") {
		t.Errorf("la solución debe decir qué hacer con el módulo: %q", it.Fix)
	}
	if !strings.Contains(it.Detail, "/sys/fs/pstore/dmesg-efi-166") {
		t.Errorf("el detalle debe decir de dónde salió: %q", it.Detail)
	}
}

func TestAplicaDictamenEnriqueceElFalloYaListado(t *testing.T) {
	cuando := time.Date(2026, 8, 25, 9, 0, 0, 0, time.Local)
	rep := &ErrorsReport{Items: []SystemError{{
		ID: "regla:panic|kernel", Kind: KindBSOD, When: fechaLocal(cuando.Add(30 * time.Second)),
		Title: "Fallo grave del kernel (equivalente al pantallazo azul)",
		Fix:   "Anota el módulo que aparece en el mensaje.",
	}}}
	b := parseaCrash(crashNvidia)
	b.cuando, b.fuente = cuando, "journald (registro del kernel)"
	a := analizadorDePrueba(nil)
	aplicaDictamen(rep, b, a.analiza(b))

	if len(rep.Items) != 1 {
		t.Fatalf("no debe duplicar el fallo: %d items", len(rep.Items))
	}
	if rep.Items[0].Culprit != "nvidia_drm" || rep.Items[0].Confidence != "alta" {
		t.Fatalf("%+v", rep.Items[0])
	}
}

func contieneAlgo(l []string, s string) bool {
	for _, x := range l {
		if strings.Contains(x, s) {
			return true
		}
	}
	return false
}

// De punta a punta: un fallo que solo existe en el disco (kdump/pstore) tiene
// que aparecer como pantallazo, con su causante, su tarjeta de controladores
// señalados y el archivo en la lista de volcados para llevárselo.
func TestAnalizaPanicosDePunta(t *testing.T) {
	raiz := t.TempDir()
	dir := filepath.Join(raiz, "crash", "2026-08-25-12:00:00")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "vmcore-dmesg.txt"), []byte(crashNvidia), 0o644); err != nil {
		t.Fatal(err)
	}
	viejoCrash, viejoPstore, viejoSystemd := dirCrash, dirPstore, dirPstoreSystemd
	dirCrash = filepath.Join(raiz, "crash")
	dirPstore = filepath.Join(raiz, "vacio")
	dirPstoreSystemd = filepath.Join(raiz, "vacio")
	defer func() { dirCrash, dirPstore, dirPstoreSystemd = viejoCrash, viejoPstore, viejoSystemd }()

	rep := &ErrorsReport{Items: []SystemError{}, Dumps: []DumpFile{}}
	analizaPanicos(rep, nil)

	if rep.DumpsAnalyzed != 1 {
		t.Fatalf("fallos analizados = %d", rep.DumpsAnalyzed)
	}
	if rep.AnalyzedLabel != "1 fallo del kernel analizado" {
		t.Errorf("etiqueta = %q", rep.AnalyzedLabel)
	}
	if len(rep.CulpritsNote) == 0 {
		t.Error("falta la explicación de qué se cruzó")
	}
	if len(rep.Items) != 1 || rep.Items[0].Culprit != "nvidia_drm" {
		t.Fatalf("items = %+v", rep.Items)
	}
	if len(rep.Culprits) == 0 || rep.Culprits[0].Driver != "nvidia_drm" {
		t.Fatalf("controladores señalados = %+v", rep.Culprits)
	}
	if rep.Culprits[0].InStack != 1 || rep.Culprits[0].Total != 1 {
		t.Errorf("cruce mal contado: %+v", rep.Culprits[0])
	}
	var hallado bool
	for _, d := range rep.Dumps {
		if strings.HasSuffix(d.Path, "vmcore-dmesg.txt") {
			hallado = true
		}
	}
	if !hallado {
		t.Error("el archivo del fallo debe salir en la lista de volcados")
	}
}

// La fila de "fallo grave del kernel" agrupa TODAS las caídas del periodo y
// solo guarda la primera y la última fecha. Un bloque de journald de una caída
// intermedia no casa por fecha con ninguna, y aun así no puede crear una fila
// nueva: saldría el mismo fallo dos veces.
func TestBloqueDeJournalNoDuplicaLaFila(t *testing.T) {
	rep := &ErrorsReport{Items: []SystemError{{
		ID: "regla:panic|kernel", Kind: KindBSOD, Count: 3,
		When:      fechaLocal(time.Now()),
		FirstWhen: fechaLocal(time.Now().AddDate(0, 0, -20)),
		Title:     "Fallo grave del kernel (equivalente al pantallazo azul)",
	}}}
	b := parseaCrash(crashNvidia)
	b.cuando = time.Now().AddDate(0, 0, -10) // ni la primera ni la última
	b.fuente = "journald (registro del kernel)"
	a := analizadorDePrueba(nil)
	aplicaDictamen(rep, b, a.analiza(b))

	if len(rep.Items) != 1 {
		t.Fatalf("no debe crear una fila nueva: %d items", len(rep.Items))
	}
	if rep.Items[0].Culprit != "nvidia_drm" {
		t.Errorf("el análisis debe colgarse de la fila que ya existe: %+v", rep.Items[0])
	}
}
