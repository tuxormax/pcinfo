package collector

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
)

// TestParseSMBIOSTablaReal contrasta el parser contra dmidecode usando la tabla
// DMI de la máquina donde corre el test. Se salta si no hay tabla o dmidecode
// (p.ej. sin root, o en CI de Windows). Windows lee la misma tabla, con el
// mismo formato, vía GetSystemFirmwareTable.
func TestParseSMBIOSTablaReal(t *testing.T) {
	raw, err := os.ReadFile("/sys/firmware/dmi/tables/DMI")
	if err != nil {
		t.Skip("sin tabla DMI legible:", err)
	}
	out, err := exec.Command("dmidecode", "-t", "17").Output()
	if err != nil {
		t.Skip("sin dmidecode:", err)
	}
	esperado := strings.Count(string(out), "\nHandle ")

	got := smbiosSlots(parseSMBIOS(raw))
	if got != esperado {
		t.Fatalf("ranuras (Type 17) = %d, dmidecode dice %d", got, esperado)
	}
	if got == 0 {
		t.Fatal("el parser no encontró ningún registro Type 17")
	}

	// Y los locators de cada ranura deben coincidir con los de dmidecode.
	var locs []string
	for _, s := range parseSMBIOS(raw) {
		if s.Type == 17 {
			locs = append(locs, s.str(0x10))
		}
	}
	for _, l := range locs {
		if l == "" {
			t.Error("ranura sin Locator: fallo al leer el área de cadenas")
		}
		if !strings.Contains(string(out), l) {
			t.Errorf("Locator %q no aparece en dmidecode", l)
		}
	}
	t.Log("ranuras:", strconv.Itoa(got), locs)
}
