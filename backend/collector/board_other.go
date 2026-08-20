//go:build !windows

package collector

// En Linux el BIOS sale completo del DMI (/sys/class/dmi/id), que es lo que lee
// ghw: no hay nada que corregir. Ver la versión de Windows de este archivo para
// el porqué.
func afinaBIOS(*BoardInfo) {}
