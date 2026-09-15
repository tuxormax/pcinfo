//go:build linux

package collector

import (
	"bufio"
	"encoding/binary"
	"net"
	"os"
	"strconv"
	"strings"
)

// defaultGateway lee /proc/net/route: la ruta con Destination 00000000 es la
// ruta por defecto. El campo Gateway viene en hexadecimal little-endian (al
// revés de como se escribe una IP). Sin exec ni root, igual que el resto de
// los colectores de Linux (todo por /proc y /sys).
func defaultGateway() (gateway, iface string) {
	f, err := os.Open("/proc/net/route")
	if err != nil {
		return "", ""
	}
	defer f.Close()

	mejorMetric := -1
	sc := bufio.NewScanner(f)
	sc.Scan() // encabezado
	for sc.Scan() {
		campos := strings.Fields(sc.Text())
		if len(campos) < 8 {
			continue
		}
		if campos[1] != "00000000" { // Destination
			continue
		}
		metric, _ := strconv.Atoi(campos[6])
		if gateway != "" && metric >= mejorMetric {
			continue
		}
		ip := hexRouteToIP(campos[2])
		if ip == "" {
			continue
		}
		gateway = ip
		iface = campos[0]
		mejorMetric = metric
	}
	return gateway, iface
}

// hexRouteToIP convierte el campo Gateway/Destination de /proc/net/route
// (hex little-endian, ej. "0101A8C0" = 192.168.1.1) a texto punteado.
func hexRouteToIP(hexLE string) string {
	v, err := strconv.ParseUint(hexLE, 16, 32)
	if err != nil {
		return ""
	}
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, uint32(v))
	ip := net.IPv4(b[0], b[1], b[2], b[3])
	if ip.IsUnspecified() {
		return ""
	}
	return ip.String()
}
