package collector

import "encoding/binary"

// Parser de la tabla SMBIOS cruda. Lo usamos en Windows (ver smbios_windows.go)
// porque WMI no expone las ranuras de RAM VACÍAS: Win32_PhysicalMemory solo
// lista módulos instalados y Win32_PhysicalMemoryArray.MemoryDevices (SMBIOS
// Type 16) viene mal en mucho firmware — la Gigabyte A520M K V2 declara 4
// ranuras cuando físicamente tiene 2. La cuenta fiable es el número de
// registros Type 17: uno por ranura física, esté ocupada o no. Es lo que hacen
// CPU-Z/HWiNFO. En Linux el equivalente lo da dmidecode.

// smbiosStruct es un registro de la tabla: tipo, área formateada y sus cadenas.
type smbiosStruct struct {
	Type    byte
	Data    []byte   // área formateada, incluida la cabecera de 4 bytes
	Strings []string // índice 1 = Strings[0], como manda la spec
}

// str devuelve la cadena referenciada por el byte en el offset dado (1-based;
// 0 = sin cadena).
func (s smbiosStruct) str(off int) string {
	if off >= len(s.Data) {
		return ""
	}
	i := int(s.Data[off])
	if i == 0 || i > len(s.Strings) {
		return ""
	}
	return s.Strings[i-1]
}

func (s smbiosStruct) u16(off int) uint16 {
	if off+2 > len(s.Data) {
		return 0
	}
	return binary.LittleEndian.Uint16(s.Data[off:])
}

// parseSMBIOS recorre los registros: cabecera de 4 bytes (tipo, largo, handle),
// área formateada de `largo` bytes y a continuación las cadenas, terminadas por
// un doble cero.
func parseSMBIOS(b []byte) []smbiosStruct {
	var out []smbiosStruct
	for i := 0; i+4 <= len(b); {
		typ, length := b[i], int(b[i+1])
		if length < 4 || i+length > len(b) {
			break
		}
		st := smbiosStruct{Type: typ, Data: b[i : i+length]}

		// Área de cadenas hasta el doble cero.
		j := i + length
		for j < len(b) {
			if b[j] == 0 { // fin de una cadena, o del área si sigue otro cero
				if j+1 < len(b) && b[j+1] == 0 {
					j += 2
					break
				}
				j++
				continue
			}
			k := j
			for k < len(b) && b[k] != 0 {
				k++
			}
			st.Strings = append(st.Strings, string(b[j:k]))
			j = k
		}
		out = append(out, st)
		if typ == 127 { // End-of-table
			break
		}
		i = j
	}
	return out
}

// smbiosSlots cuenta los registros Type 17 = ranuras físicas, ocupadas o no.
func smbiosSlots(tables []smbiosStruct) int {
	n := 0
	for _, s := range tables {
		if s.Type == 17 {
			n++
		}
	}
	return n
}
