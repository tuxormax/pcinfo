//go:build darwin

package collector

import "runtime"

// enrichCPU corrige y completa la CPU en un Mac.
//
// ⛔ Lo primero que arregla es un dato MAL: `ghw` en darwin pone como fabricante
// el nombre del TIPO DE NÚCLEO ("Performance"), no el fabricante. Se comprobó en
// la Mac mini M4 el 12-sep-2026: la ficha mostraba «Fabricante: Performance».
// En un Apple Silicon el fabricante es Apple; en un Mac Intel se pregunta a
// sysctl.
//
// La frecuencia base solo existe en los Mac Intel (`hw.cpufrequency`): Apple no
// la expone en los suyos, así que ahí la fila se queda vacía, que es la verdad.
func enrichCPU(out *CPUInfo) {
	if runtime.GOARCH == "arm64" {
		out.Vendor = "Apple"
	} else if v := sysctlTexto("machdep.cpu.vendor"); v != "" {
		out.Vendor = v
	}

	if out.Model == "" {
		out.Model = sysctlTexto("machdep.cpu.brand_string")
	}
	if out.Cores == 0 {
		out.Cores = int(sysctlEntero("machdep.cpu.core_count"))
	}
	if out.Threads == 0 {
		out.Threads = int(sysctlEntero("machdep.cpu.thread_count"))
	}

	// Hz → MHz. En Apple Silicon devuelve 0 y la fila no se pinta.
	if out.BaseMhz == 0 {
		if hz := sysctlEntero("hw.cpufrequency"); hz > 0 {
			out.BaseMhz = float64(hz) / 1e6
		}
	}
	if out.MaxMhz == 0 {
		if hz := sysctlEntero("hw.cpufrequency_max"); hz > 0 {
			out.MaxMhz = float64(hz) / 1e6
		}
	}
}
