package collector

import (
	"net"
	"runtime"
)

// Módulo "Red": diagnóstico de Internet por capas y test de velocidad — SOLO
// LECTURA, no escribe nada en el equipo. El backend solo aporta lo que
// necesita permisos u OS-específico (IP local y puerta de enlace); el resto
// del diagnóstico (ping, DNS, portal cautivo, UPnP…) lo hace la GUI Flutter
// directamente, igual que RedScan (proyecto primo): son operaciones de socket
// normales que no necesitan ni WMI ni elevación.

// RedInfo es la respuesta de GET /red.
type RedInfo struct {
	OS        string `json:"os"`
	LocalIP   string `json:"localIp"`
	Gateway   string `json:"gateway"`   // vacío si no se pudo determinar
	Interface string `json:"interface"` // nombre de la interfaz de red usada
}

// CollectRed arma la información de red que solo el sistema operativo sabe
// dar (IP local y puerta de enlace por defecto).
func CollectRed() RedInfo {
	rep := safe("red", redLocal)
	if rep.OS == "" {
		rep.OS = runtime.GOOS
	}
	return rep
}

// defaultGateway lo implementa cada plataforma (red_windows.go, red_linux.go,
// red_darwin.go): devuelve la puerta de enlace y la interfaz de la ruta por
// defecto (0.0.0.0/0), o vacío si no se pudo determinar.
func redLocal() RedInfo {
	rep := RedInfo{OS: runtime.GOOS, LocalIP: localIP()}
	rep.Gateway, rep.Interface = defaultGateway()
	return rep
}

// localIP es la IP con la que el equipo saldría a internet: se "conecta" por
// UDP a una IP pública sin enviar ningún paquete (UDP no hace handshake), y el
// sistema operativo resuelve sola la interfaz/IP de origen según su tabla de
// rutas. Funciona sin admin/root y aunque no haya internet de verdad.
func localIP() string {
	conn, err := net.Dial("udp", "1.1.1.1:80")
	if err != nil {
		return ""
	}
	defer conn.Close()
	addr, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return ""
	}
	return addr.IP.String()
}
