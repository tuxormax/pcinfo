//go:build windows

package collector

import (
	"syscall"
	"unsafe"
)

var (
	kernel32              = syscall.NewLazyDLL("kernel32.dll")
	procGetDiskFreeSpaceEx = kernel32.NewProc("GetDiskFreeSpaceExW")
)

// diskUsage devuelve los bytes ocupados y disponibles del volumen montado en
// mountpoint (Windows, vía GetDiskFreeSpaceExW; el mountpoint suele ser "C:\").
// ok=false si la llamada falla. avail = bytes libres disponibles al usuario;
// used = total − total libres.
func diskUsage(mountpoint string) (used, avail uint64, ok bool) {
	p, err := syscall.UTF16PtrFromString(mountpoint)
	if err != nil {
		return 0, 0, false
	}
	var freeAvail, total, totalFree uint64
	r, _, _ := procGetDiskFreeSpaceEx.Call(
		uintptr(unsafe.Pointer(p)),
		uintptr(unsafe.Pointer(&freeAvail)),
		uintptr(unsafe.Pointer(&total)),
		uintptr(unsafe.Pointer(&totalFree)),
	)
	if r == 0 || total == 0 {
		return 0, 0, false
	}
	used = total - totalFree
	avail = freeAvail
	return used, avail, true
}
