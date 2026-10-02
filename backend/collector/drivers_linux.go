//go:build linux

package collector

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Redes WiFi en Linux (NetworkManager). Los controladores NO aplican: en Linux
// van en el kernel y los gestiona la distribución (restaurar los de otro equipo
// solo podría romper el arranque), así que aquí el módulo es solo de WiFi.
//
// NetworkManager guarda cada red como un archivo de texto (keyfile) en
// /etc/NetworkManager/system-connections/, legible solo por root, con la
// contraseña en claro (`psk=`) cuando es de todo el sistema. Respaldar = copiar
// esos archivos; restaurar = copiarlos de vuelta con permisos 0600 y pedir a
// NetworkManager que los relea.

const dirNM = "/etc/NetworkManager/system-connections"

// conexionNM es lo que importa de un archivo de NetworkManager.
type conexionNM struct {
	Archivo string
	Wifi    bool
	ID      string
	SSID    string
	Auth    string
	PSK     string
}

func estadoControladores() DriversReport {
	rep := DriversReport{
		OS:         "linux",
		Supported:  true,
		Elevated:   isElevated(),
		Drivers:    []DriverItem{},
		Wifi:       []WifiProfile{},
		Pendientes: []DispositivoPendiente{},
		Reason: "En Linux los controladores van en el kernel y los gestiona la distribución: " +
			"aquí solo se respaldan y restauran las redes WiFi de NetworkManager.",
	}
	if !rep.Elevated {
		rep.Reason = "Las redes WiFi guardadas solo las puede leer el administrador: abre PCInfo " +
			"con permisos de administrador (por ejemplo `sudo pcinfo`) para listarlas y respaldarlas."
		return rep
	}
	rep.Available = true
	conex, err := leeConexionesNM(dirNM)
	if err != nil {
		rep.Available = false
		rep.Reason = "No se pudo leer " + dirNM + " (¿el equipo usa NetworkManager?): " + err.Error()
		return rep
	}
	sinClave := 0
	for _, c := range conex {
		if !c.Wifi {
			continue
		}
		if c.PSK == "" && c.Auth != "open" {
			sinClave++
		}
		rep.Wifi = append(rep.Wifi, WifiProfile{Name: c.nombre(), Auth: c.Auth, Password: c.PSK})
	}
	if sinClave > 0 {
		rep.Reason = fmt.Sprintf("%d red(es) no guardan la contraseña a nivel de sistema (la tiene el llavero "+
			"del usuario): se respaldan sin clave y habrá que escribirla al restaurar.", sinClave)
	} else {
		rep.Reason = ""
	}
	return rep
}

func (c conexionNM) nombre() string {
	if c.SSID != "" {
		return c.SSID
	}
	return c.ID
}

// leeConexionesNM lee los keyfile de la carpeta de NetworkManager.
func leeConexionesNM(dir string) ([]conexionNM, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []conexionNM
	for _, e := range ents {
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		c, err := parseaKeyfileNM(filepath.Join(dir, e.Name()))
		if err != nil {
			warn("wifi keyfile "+e.Name(), err)
			continue
		}
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].nombre()) < strings.ToLower(out[j].nombre()) })
	return out, nil
}

func parseaKeyfileNM(ruta string) (conexionNM, error) {
	f, err := os.Open(ruta)
	if err != nil {
		return conexionNM{}, err
	}
	defer f.Close()
	c := conexionNM{Archivo: ruta, Auth: "open"}
	seccion := ""
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		if strings.HasPrefix(l, "[") && strings.HasSuffix(l, "]") {
			seccion = l[1 : len(l)-1]
			continue
		}
		k, v, ok := strings.Cut(l, "=")
		if !ok {
			continue
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		switch seccion + "." + k {
		case "connection.type":
			c.Wifi = v == "wifi" || v == "802-11-wireless"
		case "connection.id":
			c.ID = v
		case "wifi.ssid", "802-11-wireless.ssid":
			c.SSID = v
		case "wifi-security.key-mgmt", "802-11-wireless-security.key-mgmt":
			c.Auth = v
		case "wifi-security.psk", "802-11-wireless-security.psk":
			c.PSK = v
		}
	}
	return c, sc.Err()
}

func respaldaControladores(_ context.Context, _ string) error { return noDisponible() }
func restauraControladores(_ context.Context, _ string) error { return noDisponible() }

func respaldaWifi(_ context.Context, carpeta string) error {
	conex, err := leeConexionesNM(dirNM)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(carpeta, 0o700); err != nil {
		return err
	}
	n := 0
	for _, c := range conex {
		if !c.Wifi {
			continue
		}
		datos, err := os.ReadFile(c.Archivo)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(carpeta, filepath.Base(c.Archivo)), datos, 0o600); err != nil {
			return err
		}
		paso(PasoInfo, "Respaldada: "+c.nombre())
		n++
	}
	if n == 0 {
		return fmt.Errorf("no hay redes WiFi guardadas que respaldar")
	}
	return nil
}

func restauraWifi(ctx context.Context, carpeta string) error {
	ents, err := os.ReadDir(carpeta)
	if err != nil {
		return fmt.Errorf("no se encontró la carpeta del respaldo %s: %w", carpeta, err)
	}
	if err := os.MkdirAll(dirNM, 0o755); err != nil {
		return err
	}
	n := 0
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		origen := filepath.Join(carpeta, e.Name())
		c, err := parseaKeyfileNM(origen)
		if err != nil || !c.Wifi {
			continue
		}
		datos, err := os.ReadFile(origen)
		if err != nil {
			return err
		}
		dest := filepath.Join(dirNM, e.Name())
		if err := os.WriteFile(dest, datos, 0o600); err != nil {
			return err
		}
		_ = os.Chmod(dest, 0o600) // si ya existía, WriteFile no cambia los permisos
		paso(PasoInfo, "Añadida: "+c.nombre())
		n++
	}
	if n == 0 {
		return fmt.Errorf("el respaldo no trae ninguna red WiFi (.nmconnection)")
	}
	if out, err := exec.CommandContext(ctx, "nmcli", "connection", "reload").CombinedOutput(); err != nil {
		paso(PasoAviso, "Se copiaron las redes pero NetworkManager no las recargó ("+
			strings.TrimSpace(string(out))+"). Reinícialo: sudo systemctl restart NetworkManager")
	}
	return nil
}

func noDisponible() error {
	return fmt.Errorf("esta operación no está disponible en Linux")
}
