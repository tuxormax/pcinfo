//go:build !windows

package collector

// windowsSystem solo aplica en Windows; en Linux el SO se llena con os-release
// y /proc (ver collectSystem). Stub para que compile en todas las plataformas.
func windowsSystem(_ *SystemInfo) {}
