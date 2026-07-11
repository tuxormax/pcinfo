//go:build windows

package collector

import "unsafe"

// GetSystemFirmwareTable con el proveedor "RSMB" entrega la tabla SMBIOS cruda
// y NO requiere elevación (a diferencia de MSSmBios_RawSMBiosTables por WMI).
var (
	procGetSystemFirmware = kernel32.NewProc("GetSystemFirmwareTable")

	smbiosProvider uintptr = 0x52534D42 // 'RSMB' en big-endian
)

// smbiosTables devuelve todos los registros de la tabla SMBIOS. nil si el
// firmware no la expone.
func smbiosTables() []smbiosStruct {
	n, _, _ := procGetSystemFirmware.Call(smbiosProvider, 0, 0, 0)
	if n == 0 {
		return nil
	}
	buf := make([]byte, n)
	got, _, _ := procGetSystemFirmware.Call(smbiosProvider, 0,
		uintptr(unsafe.Pointer(&buf[0])), n)
	if got == 0 || got > n {
		return nil
	}
	// Cabecera RawSMBIOSData: 4 bytes de versión + Length (uint32); sigue la tabla.
	buf = buf[:got]
	if len(buf) < 8 {
		return nil
	}
	return parseSMBIOS(buf[8:])
}
