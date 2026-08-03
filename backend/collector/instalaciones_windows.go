//go:build windows

package collector

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"unsafe"
)

// Detección de instalaciones de Windows presentes en los discos del equipo.
//
// Para qué: cuando un equipo YA NO ARRANCA se le mete un medio de rescate
// (Hiren's BootCD PE, WinPE, un USB) y desde ahí el Windows averiado queda como
// una unidad más (C:, D:, …). PCInfo puede leer SU registro de eventos y SUS
// volcados aunque ese Windows no esté corriendo, que es justo cuando el
// historial de errores más sirve: dice por qué dejó de arrancar.
//
// Aquí solo se LOCALIZAN las instalaciones; leerlas es cosa de errores_windows.ps1.

var (
	procGetLogicalDrives   = kernel32.NewProc("GetLogicalDrives")
	procGetVolumeInfo      = kernel32.NewProc("GetVolumeInformationW")
	procGetDriveType       = kernel32.NewProc("GetDriveTypeW")
	version                = syscall.NewLazyDLL("version.dll")
	procGetFileVerInfoSize = version.NewProc("GetFileVersionInfoSizeW")
	procGetFileVerInfo     = version.NewProc("GetFileVersionInfoW")
)

// buscaInstalaciones recorre las unidades montadas y devuelve las que contienen
// un Windows instalado. La que está corriendo va marcada con Current y primero
// en la lista (es la opción por defecto del selector).
func buscaInstalaciones() []Install {
	actual := strings.TrimRight(systemRoot(), `\`)
	out := []Install{}

	mascara, _, _ := procGetLogicalDrives.Call()
	for i := 0; i < 26; i++ {
		if mascara&(1<<uint(i)) == 0 {
			continue
		}
		unidad := string(rune('A'+i)) + ":"
		// Las unidades de CD/DVD y las de red se saltan: montar el .evtx de un
		// recurso remoto tarda una eternidad y un DVD no trae registros útiles.
		if t := tipoUnidad(unidad + `\`); t == driveCDROM || t == driveRemote {
			continue
		}
		raiz := filepath.Join(unidad+`\`, "Windows")
		if !esInstalacionWindows(raiz) {
			continue
		}
		ins := Install{
			Root:    raiz,
			Drive:   unidad,
			Label:   etiquetaVolumen(unidad + `\`),
			Version: versionArchivo(filepath.Join(raiz, `System32\ntoskrnl.exe`)),
			Current: strings.EqualFold(raiz, actual),
		}
		out = append(out, ins)
	}

	// El sistema en ejecución SIEMPRE va en la lista, aunque no pase el filtro:
	// un WinPE (Hiren's) apenas tiene registros propios y quedaría fuera, y sin
	// él no habría forma de volver a "Este equipo" desde el selector.
	if !contieneActual(out) {
		unidad := ""
		if len(actual) >= 2 && actual[1] == ':' {
			unidad = actual[:2]
		}
		out = append(out, Install{
			Root:    actual,
			Drive:   unidad,
			Label:   etiquetaVolumen(unidad + `\`),
			Version: versionArchivo(filepath.Join(actual, `System32\ntoskrnl.exe`)),
			Current: true,
		})
	}

	sort.SliceStable(out, func(a, b int) bool { return out[a].Current && !out[b].Current })
	return out
}

func contieneActual(lista []Install) bool {
	for _, i := range lista {
		if i.Current {
			return true
		}
	}
	return false
}

// esInstalacionWindows exige el núcleo Y la carpeta de registros de eventos: sin
// los .evtx no hay nada que leer, así que ofrecerla en el selector sería engañar.
func esInstalacionWindows(raiz string) bool {
	if st, err := os.Stat(filepath.Join(raiz, `System32\ntoskrnl.exe`)); err != nil || st.IsDir() {
		return false
	}
	st, err := os.Stat(filepath.Join(raiz, `System32\winevt\Logs`))
	return err == nil && st.IsDir()
}

// resuelveRaiz valida la raíz pedida por la GUI. Devuelve la carpeta de Windows
// a analizar y un motivo si no sirve. Vacío = el sistema en ejecución.
func resuelveRaiz(pedida string) (raiz string, motivo string) {
	pedida = strings.TrimSpace(pedida)
	if pedida == "" {
		return systemRoot(), ""
	}
	pedida = strings.TrimRight(pedida, `\`)
	// Se acepta tanto "D:" como "D:\Windows": lo natural en el selector es la
	// unidad, pero el reporte guarda la raíz completa.
	if len(pedida) == 2 && pedida[1] == ':' {
		pedida = filepath.Join(pedida+`\`, "Windows")
	}
	if !esInstalacionWindows(pedida) {
		return systemRoot(), "En " + pedida + " no hay una instalación de Windows con registro de eventos legible. " +
			"Se muestra el historial del sistema que está corriendo."
	}
	return pedida, ""
}

func systemRoot() string {
	if r := os.Getenv("SystemRoot"); r != "" {
		return strings.TrimRight(r, `\`)
	}
	return `C:\Windows`
}

const (
	driveRemote = 4
	driveCDROM  = 5
)

func tipoUnidad(raiz string) uintptr {
	p, err := syscall.UTF16PtrFromString(raiz)
	if err != nil {
		return 0
	}
	t, _, _ := procGetDriveType.Call(uintptr(unsafe.Pointer(p)))
	return t
}

// etiquetaVolumen devuelve el nombre que el usuario le puso al volumen ("Datos",
// "Windows-SSD"), que es como reconoce el disco cuando hay varios.
func etiquetaVolumen(raiz string) string {
	p, err := syscall.UTF16PtrFromString(raiz)
	if err != nil {
		return ""
	}
	buf := make([]uint16, 261)
	r, _, _ := procGetVolumeInfo.Call(
		uintptr(unsafe.Pointer(p)),
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)),
		0, 0, 0, 0, 0,
	)
	if r == 0 {
		return ""
	}
	return strings.TrimSpace(syscall.UTF16ToString(buf))
}

// versionArchivo lee la versión del recurso VS_FIXEDFILEINFO de un ejecutable.
// Se usa sobre ntoskrnl.exe de cada instalación: "10.0.19045.4046" identifica al
// Windows del disco (Windows 10 22H2, en el ejemplo) SIN tener que arrancarlo ni
// montar su registro.
func versionArchivo(ruta string) string {
	p, err := syscall.UTF16PtrFromString(ruta)
	if err != nil {
		return ""
	}
	size, _, _ := procGetFileVerInfoSize.Call(uintptr(unsafe.Pointer(p)), 0)
	if size == 0 {
		return ""
	}
	datos := make([]byte, size)
	r, _, _ := procGetFileVerInfo.Call(uintptr(unsafe.Pointer(p)), 0, size, uintptr(unsafe.Pointer(&datos[0])))
	if r == 0 {
		return ""
	}
	// La estructura VS_FIXEDFILEINFO se localiza por su firma 0xFEEF04BD dentro
	// del bloque (en vez de con VerQueryValue, que obligaría a manipular punteros
	// crudos): dwFileVersionMS va 8 bytes después de la firma y dwFileVersionLS 12.
	for i := 0; i+16 <= len(datos); i += 4 {
		if binary.LittleEndian.Uint32(datos[i:]) != 0xFEEF04BD {
			continue
		}
		ms := binary.LittleEndian.Uint32(datos[i+8:])
		ls := binary.LittleEndian.Uint32(datos[i+12:])
		return fmt.Sprintf("%d.%d.%d.%d", ms>>16, ms&0xFFFF, ls>>16, ls&0xFFFF)
	}
	return ""
}
