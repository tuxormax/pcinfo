//go:build !windows

package collector

// marcaMediosWindows solo aplica a Windows: en Linux el medio removible ya lo
// da ghw (sysfs) y el S.M.A.R.T. se pide por /dev/sdX sin sondear puentes.
func marcaMediosWindows(_ []DiskInfo) {}
