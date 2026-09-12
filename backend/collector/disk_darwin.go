//go:build darwin

package collector

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Colector de discos de macOS: ejecuta los comandos; el parseo está en
// disk_darwin_parse.go (sin etiqueta de plataforma, para que se pueda probar
// desde Linux con las muestras de testdata/darwin).
//
// ⛔ NO se usa `ghw` aquí, por dos razones comprobadas en la Mac mini el
// 12-sep-2026:
//  1. `ghw` 0.24.0 trae la opción DisableTools invertida y deja el soporte de
//     bloques APAGADO en darwin: la lista de discos llega vacía.
//  2. Cuando se enciende, `ghw` llama a `diskutil info` de cada disco SIN plazo,
//     y con un disco externo conectado ese comando puede no volver nunca (macOS
//     espera a que alguien conteste un permiso de acceso al volumen). Un solo
//     disco así colgaría el inventario entero.
//
// Aquí cada llamada lleva su plazo: el disco que no contesta se salta con un
// aviso, nunca se espera y nunca se inventa el dato.

const plazoDiskutil = 6 * time.Second

// collectDisksDarwin arma la lista de discos en macOS. [conSmart]=false devuelve
// solo lo inmediato para pintar la pantalla; la salud se pide aparte, igual que
// en las otras plataformas. [forzarUSB] es el dispositivo de un disco externo
// que el usuario mandó sondear a mano desde la pestaña Discos.
func collectDisksDarwin(conSmart bool, forzarUSB string) []DiskInfo {
	disks := []DiskInfo{}

	salidaLista, err := diskutil("list")
	if err != nil {
		warn("diskutil list", err)
		return disks
	}
	fisicos, contenedores, err := separaDiscos(salidaLista)
	if err != nil {
		warn("diskutil list", err)
		return disks
	}

	for _, e := range fisicos {
		salidaInfo, err := diskutil("info", e.DeviceIdentifier)
		if err != nil {
			// No contestó a tiempo (típico: disco USB esperando un permiso del
			// sistema). ⛔ NO se descarta el disco: se muestra con lo que sí se
			// sabe por `diskutil list` y sin inventar modelo ni bus.
			warn("diskutil info "+e.DeviceIdentifier, err)
			if di, ok := discoDesdeLista(e, contenedores); ok {
				disks = append(disks, di)
			}
			continue
		}
		di, ok := discoDesdeInfo(e, salidaInfo, contenedores)
		if !ok {
			continue
		}
		disks = append(disks, di)
	}

	if !conSmart {
		return disks
	}

	// S.M.A.R.T. en paralelo, igual que en Linux: cada smartctl ya trae su plazo,
	// así que el total es el del disco más lento y no la suma.
	// ⭐ En Apple Silicon el SSD interno SÍ lo reporta por /dev/diskN (comprobado
	// en la M4, y sin hacer falta root).
	var wg sync.WaitGroup
	for i := range disks {
		wg.Add(1)
		go func(di *DiskInfo) {
			defer wg.Done()
			readSmart(di)
		}(&disks[i])
	}
	wg.Wait()

	// ⛔ AQUÍ NO SE SONDEAN TIPOS DE PUENTE USB, y no es un olvido.
	// En Windows, un disco en gabinete externo sí entrega su salud si se le habla
	// con `-d sat` (o usbjmicron, usbasm1051…), y para eso está probeSmartUSB.
	// En macOS **ninguno de esos tipos puede funcionar**: la documentación de
	// smartmontools para Darwin dice que el soporte SCSI no está implementado, y
	// se comprobó con el disco de 2 TB de tuxor el 12-sep-2026 —`/dev/disk4`
	// contesta *"Operation not supported by device"* y cada `-d <tipo>` responde
	// *"Not a device of type 'scsi'"*. Sondear los cinco tipos serían **20
	// segundos de espera por cada consulta** para un resultado que se sabe de
	// antemano. El porqué se le explica al usuario en la ficha del disco
	// (disco_salud_darwin.go).
	// [forzarUSB] se acepta por concordancia con las otras plataformas, pero aquí
	// no hay nada que forzar: el límite es del sistema, no del tiempo de espera.
	var log strings.Builder
	fmt.Fprintf(&log, "macOS · smartctl bin: %s · forzar=%q\n", smartctlBin(), forzarUSB)
	for i := range disks {
		fmt.Fprintf(&log, "%s: smart=%v modelo=%q bus=%q tipo=%q\n",
			disks[i].Name, disks[i].SmartAvailable, disks[i].Model,
			disks[i].Bus, disks[i].Type)
	}
	writeSmartDebug(log.String())

	for i := range disks {
		interpretaDisco(&disks[i])
	}
	return disks
}

// diskutil ejecuta `diskutil <verbo> -plist <resto>` con plazo duro.
// ⚠️ El `-plist` va JUSTO DESPUÉS del verbo: `diskutil info disk0 -plist` sale
// con código 1 ("Unrecognized argument"), el orden importa.
func diskutil(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), plazoDiskutil)
	defer cancel()
	con := append([]string{args[0], "-plist"}, args[1:]...)
	out, err := exec.CommandContext(ctx, "diskutil", con...).Output()
	if err != nil {
		return nil, err
	}
	return out, nil
}
