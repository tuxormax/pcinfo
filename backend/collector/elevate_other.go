//go:build !windows

package collector

import "os"

// isElevated en Linux/macOS: root (euid 0). El .deb instala el backend como
// servicio root, así que normalmente es true; en dev sin root sería false y la
// GUI lo reflejaría igual que en Windows.
func isElevated() bool { return os.Geteuid() == 0 }
