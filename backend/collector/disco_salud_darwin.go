//go:build darwin

package collector

import "strings"

// motivoSinSaludDarwin explica por qué un disco no informa de su salud EN UN MAC.
// Hace falta aparte porque los motivos genéricos no valen aquí:
//   - el de Linux manda instalar smartmontools con `apt`, que en macOS no existe;
//   - el de "ejecútalo como administrador" es **falso** en un Mac: el SSD interno
//     entrega su S.M.A.R.T. sin root, y en un disco USB ser root no cambia nada.
//
// ⛔ Lo de USB es un **límite del sistema**, no algo pendiente de programar: la
// propia documentación de smartmontools para Darwin dice que el soporte SCSI no
// está implementado y que para leer discos USB/FireWire hace falta instalar el
// *SAT SMART Driver*, un controlador de terceros que en un Apple Silicon exige
// bajar la seguridad del arranque. Y `diskutil` opina lo mismo: en el disco de
// pruebas (gabinete JMicron de 2 TB) contesta `SMARTStatus: Not Supported`.
func motivoSinSaludDarwin(d *DiskInfo) string {
	if !smartctlAvailable() {
		return "Falta la herramienta que le pregunta la salud a los discos " +
			"(smartctl). PCInfo la trae dentro: vuelve a instalarlo."
	}
	if b := strings.ToLower(d.Bus); strings.Contains(b, "usb") {
		return "macOS no puede leer la salud de un disco conectado por USB: el " +
			"sistema no traduce esas preguntas a través del adaptador, y ejecutarlo " +
			"como administrador tampoco cambia nada. No significa que el disco esté " +
			"mal. Para revisarlo, conéctalo a un equipo donde vaya por dentro, o " +
			"míralo desde Linux o Windows, que sí leen la salud a través del USB."
	}
	return "Este disco no contesta cuando se le pregunta por su salud. No " +
		"significa que esté mal: hay conexiones —algunos gabinetes, controladoras " +
		"RAID— que no dejan pasar la pregunta."
}
