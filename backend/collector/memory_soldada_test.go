package collector

import "testing"

func TestMarcaSoldadasLenovo(t *testing.T) {
	out := MemoryInfo{TotalSlots: 2, Modules: []MemModule{
		{SizeBytes: 4 << 30, FormFactor: "SODIMM"},
		{SizeBytes: 4 << 30, FormFactor: ""},
	}}
	marcaSoldadas(&out)
	if out.Soldered || out.SolderedBytes != 4<<30 || out.TotalSlots != 1 ||
		modulosEnRanura(out.Modules) != 1 || out.Modules[1].FormFactor != formatoSoldado {
		t.Fatalf("mezcla mal detectada: %+v", out)
	}
}

func TestMarcaSoldadasSinRanuras(t *testing.T) {
	out := MemoryInfo{TotalSlots: 2, Modules: []MemModule{
		{SizeBytes: 8 << 30, FormFactor: "Row Of Chips"},
		{SizeBytes: 8 << 30, FormFactor: "Row Of Chips"},
	}}
	marcaSoldadas(&out)
	if !out.Soldered || out.TotalSlots != 2 {
		t.Fatalf("todo soldado mal: %+v", out)
	}
	// Sin formato en ninguno: no se adivina.
	out = MemoryInfo{TotalSlots: 2, Modules: []MemModule{{SizeBytes: 4 << 30}, {SizeBytes: 4 << 30}}}
	marcaSoldadas(&out)
	if out.SolderedBytes != 0 || out.TotalSlots != 2 {
		t.Fatalf("no debía marcar soldada: %+v", out)
	}
}
