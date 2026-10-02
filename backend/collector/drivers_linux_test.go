//go:build linux

package collector

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseaKeyfileNM(t *testing.T) {
	d := t.TempDir()
	r := filepath.Join(d, "Casa.nmconnection")
	os.WriteFile(r, []byte("[connection]\nid=Casa\ntype=wifi\n\n[wifi]\nssid=MiCasa\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=secreto123\n"), 0o600)
	c, err := parseaKeyfileNM(r)
	if err != nil || !c.Wifi || c.nombre() != "MiCasa" || c.Auth != "wpa-psk" || c.PSK != "secreto123" {
		t.Fatalf("mal: %+v %v", c, err)
	}
	e := filepath.Join(d, "eth.nmconnection")
	os.WriteFile(e, []byte("[connection]\nid=eth\ntype=ethernet\n"), 0o600)
	if c, _ := parseaKeyfileNM(e); c.Wifi {
		t.Fatal("ethernet no es wifi")
	}
}
