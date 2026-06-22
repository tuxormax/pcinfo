package collector

import (
	"bufio"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

func collectSystem() SystemInfo {
	host, _ := os.Hostname()
	s := SystemInfo{
		Hostname: host,
		Arch:     archName(),
	}
	switch runtime.GOOS {
	case "linux":
		s.Distro = linuxDistro()
		s.Kernel = readTrim("/proc/sys/kernel/osrelease")
		s.Desktop = linuxDesktop()
	case "windows":
		// ghw/WMI no exponen esto directo; se completa con datos del SO.
		s.Distro = windowsCaption()
		s.Kernel = osBuild()
	default:
		s.Distro = runtime.GOOS
	}
	return s
}

// archName devuelve la arquitectura en notación uname ("x86_64") en vez de la
// de Go ("amd64").
func archName() string {
	if runtime.GOOS == "linux" {
		if m := cmdOut("uname", "-m"); m != "" {
			return m
		}
	}
	switch runtime.GOARCH {
	case "amd64":
		return "x86_64"
	case "386":
		return "i686"
	case "arm64":
		return "aarch64"
	default:
		return runtime.GOARCH
	}
}

// linuxDistro lee PRETTY_NAME de /etc/os-release.
func linuxDistro() string {
	for _, path := range []string{"/etc/os-release", "/usr/lib/os-release"} {
		f, err := os.Open(path)
		if err != nil {
			continue
		}
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
				return strings.Trim(v, `"`)
			}
		}
	}
	return ""
}

// linuxDesktop combina el entorno de escritorio y el tipo de sesión.
func linuxDesktop() string {
	de := firstNonEmpty(
		os.Getenv("XDG_CURRENT_DESKTOP"),
		os.Getenv("DESKTOP_SESSION"),
	)
	if de == "" {
		return ""
	}
	if sess := os.Getenv("XDG_SESSION_TYPE"); sess != "" {
		return de + " (" + sess + ")"
	}
	return de
}

func windowsCaption() string { return cmdOut("cmd", "/c", "ver") }
func osBuild() string        { return "" }

func readTrim(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func cmdOut(name string, args ...string) string {
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}
