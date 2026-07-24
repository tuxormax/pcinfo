//go:build linux

package collector

import (
	"testing"
	"time"
)

// Verifica que el catálogo traduzca los mensajes clave del kernel a la categoría
// correcta. Es la parte que decide si un fallo se le presenta al usuario como
// "disco muriendo" o como un aviso inofensivo, así que conviene blindarla.
func TestClasificaMensajes(t *testing.T) {
	casos := []struct {
		msg  string
		id   string
		kind string
		sev  string
	}{
		{"kernel: Kernel panic - not syncing: Fatal exception", "panic", KindBSOD, SevCritico},
		{"kernel: mce: [Hardware Error]: Machine check events logged", "mce", KindHardware, SevCritico},
		{"kernel: Out of memory: Killed process 4242 (firefox)", "oom", KindMemoria, SevError},
		{"kernel: critical medium error, dev sda, sector 123456", "medio", KindDisco, SevCritico},
		{"kernel: ata3.00: failed command: READ FPDMA QUEUED", "ata", KindDisco, SevError},
		{"kernel: EXT4-fs error (device sda2): ext4_find_entry:1616", "fs", KindDisco, SevCritico},
		{"kernel: NVRM: Xid (PCI:0000:09:00): 79, GPU has fallen off the bus", "gpu", KindGrafica, SevError},
		{"kernel: firefox[1234]: segfault at 0 ip 00007f err 4 in libxul.so", "segfault", KindApp, SevError},
		{"systemd: Failed to start Bluetooth service.", "servicio", KindServicio, SevError},
		// Ruido conocido: debe salir como AVISO, no como error alarmante.
		{"kernel: ACPI BIOS Error (bug): Failure creating named object", "acpi", KindSistema, SevAviso},
		{"bluetoothd: sap-server: Operation not permitted (1)", "bluetooth", KindSistema, SevAviso},
	}
	for _, c := range casos {
		r := clasifica(c.msg)
		if r == nil {
			t.Errorf("sin regla para %q (esperaba %s)", c.msg, c.id)
			continue
		}
		if r.id != c.id || r.kind != c.kind || r.severity != c.sev {
			t.Errorf("%q → regla %s/%s/%s; esperaba %s/%s/%s",
				c.msg, r.id, r.kind, r.severity, c.id, c.kind, c.sev)
		}
	}
}

// Las repeticiones del MISMO problema deben colapsar en un solo elemento con su
// contador y su rango de fechas; problemas de servicios distintos, no.
func TestAgrupaEntradas(t *testing.T) {
	base := time.Date(2026, 7, 20, 10, 0, 0, 0, time.Local)
	ents := []entradaLog{
		{when: base.Add(2 * time.Hour), msg: "Failed to start Bluetooth service.", ident: "systemd", unit: "bluetooth.service", prio: 3},
		{when: base, msg: "Failed to start Bluetooth service.", ident: "systemd", unit: "bluetooth.service", prio: 3},
		{when: base.Add(time.Hour), msg: "Failed to start CUPS.", ident: "systemd", unit: "cups.service", prio: 3},
	}
	items := agrupaEntradas(ents)
	if len(items) != 2 {
		t.Fatalf("se esperaban 2 problemas agrupados, hubo %d", len(items))
	}
	bt := items[0]
	if bt.Count != 2 {
		t.Errorf("bluetooth.service debía contar 2 apariciones, contó %d", bt.Count)
	}
	if bt.When != "2026-07-20 12:00:00" || bt.FirstWhen != "2026-07-20 10:00:00" {
		t.Errorf("rango de fechas incorrecto: %q … %q", bt.FirstWhen, bt.When)
	}
	if bt.Culprit != "bluetooth.service" {
		t.Errorf("no se identificó la unidad afectada: %q", bt.Culprit)
	}
	if items[1].Count != 1 || items[1].FirstWhen != "" {
		t.Errorf("un problema visto una sola vez no debe llevar rango: %+v", items[1])
	}
}

// Las entradas del barrido de avisos del kernel que no casan con el catálogo se
// descartan (si no, la lista se llenaría de ruido de arranque).
func TestSoloReglaDescartaRuido(t *testing.T) {
	ents := []entradaLog{
		{when: time.Now(), msg: "algo irrelevante del kernel", ident: "kernel", prio: 4, soloRegla: true},
		{when: time.Now(), msg: "ata1.00: exception Emask 0x0", ident: "kernel", prio: 4, soloRegla: true},
	}
	items := agrupaEntradas(ents)
	if len(items) != 1 || items[0].Kind != KindDisco {
		t.Fatalf("solo debía quedar el error de disco, quedó %+v", items)
	}
}
