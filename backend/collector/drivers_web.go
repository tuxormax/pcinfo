package collector

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// Descarga e instalación de controladores del catálogo del fabricante
// (POST /controladores/descargar → tarea "descargar"). La descarga y la
// verificación del hash son Go puro (se prueban en Linux); instalar es de cada
// sistema (drivers_web_windows.go).

// TareaDescargar es el Kind de la tarea que baja e instala controladores.
const TareaDescargar = "descargar"

// clienteWeb no lleva Timeout global: un paquete grande tarda y manda el ctx.
// Es variable para que las pruebas usen el cliente de su servidor TLS.
var clienteWeb = &http.Client{}

// maxDescargaWeb es el tope de un paquete (los de gráficos rondan 1 GB).
const maxDescargaWeb = 2 << 30

// IniciaDescarga arranca la descarga e instalación de las filas elegidas.
func IniciaDescarga(ids []string) (TareaInfo, error) {
	if len(ids) == 0 {
		return TareaInfo{}, fmt.Errorf("no se eligió ningún controlador")
	}
	elegidos := []DriverWeb{}
	for _, id := range ids {
		d, ok := driverWebPorID(id)
		if !ok {
			return TareaInfo{}, fmt.Errorf("el controlador %q ya no está en el catálogo", id)
		}
		elegidos = append(elegidos, d)
	}
	rep := CollectDrivers()
	if !rep.Supported || !rep.DriversAplica {
		return TareaInfo{}, fmt.Errorf("instalar controladores solo está disponible en Windows")
	}
	if !rep.Elevated {
		return TareaInfo{}, fmt.Errorf("hace falta ejecutar PCInfo como administrador para instalar controladores")
	}
	return arrancaTareaGenerica(TareaDescargar, TareaInfo{Drivers: true, Folder: "Descargas de PCInfo"},
		func(ctx context.Context) error { return descargaEInstala(ctx, elegidos) })
}

// carpetaDriversWeb es donde se guardan los paquetes bajados, una subcarpeta por
// fabricante (…\PCInfo\drivers\HP\…). NO son temporales: se conservan para no
// volver a bajar GB si hay que reinstalar o llevarlos a otro equipo.
func carpetaDriversWeb(fabricante string) string {
	base := os.Getenv("ProgramData")
	if base == "" {
		if d, err := os.UserCacheDir(); err == nil {
			base = d
		} else {
			base = os.TempDir()
		}
	}
	seguro := strings.Map(func(r rune) rune {
		if strings.ContainsRune(`\/:*?"<>|`, r) || r < 32 {
			return '_'
		}
		return r
	}, strings.TrimSpace(fabricante))
	if seguro == "" {
		seguro = "otros"
	}
	return filepath.Join(base, "PCInfo", "drivers", seguro)
}

// hashArchivo devuelve el SHA-256 de un archivo, o "" si no se puede leer.
func hashArchivo(ruta string) string {
	f, err := os.Open(ruta)
	if err != nil {
		return ""
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}

func descargaEInstala(ctx context.Context, lista []DriverWeb) error {
	var fallos []string
	for i, d := range lista {
		carpeta := carpetaDriversWeb(d.Fabricante)
		if err := os.MkdirAll(carpeta, 0o755); err != nil {
			paso(PasoError, d.Nombre+": no se pudo crear "+carpeta+": "+err.Error())
			fallos = append(fallos, d.Nombre)
			continue
		}
		// El hash va en el nombre: si el catálogo cambia de versión no se reutiliza
		// por error un archivo viejo.
		archivo := filepath.Join(carpeta, d.ID+"-"+d.SHA256[:8]+"."+d.Tipo)
		if hashArchivo(archivo) == d.SHA256 {
			paso(PasoInfo, fmt.Sprintf("(%d/%d) %s: ya estaba descargado en %s", i+1, len(lista), d.Nombre, carpeta))
		} else {
			paso(PasoInfo, fmt.Sprintf("(%d/%d) %s %s: descargando a %s…", i+1, len(lista), d.Fabricante, d.Nombre, carpeta))
			if err := bajaVerificado(ctx, d.URL, d.SHA256, archivo); err != nil {
				paso(PasoError, d.Nombre+": "+err.Error())
				fallos = append(fallos, d.Nombre)
				if ctx.Err() != nil {
					break
				}
				continue
			}
			paso(PasoInfo, d.Nombre+": descarga verificada.")
		}
		paso(PasoInfo, d.Nombre+": instalando…")
		if err := instalaPaqueteWeb(ctx, d, archivo); err != nil {
			paso(PasoError, d.Nombre+": "+err.Error())
			fallos = append(fallos, d.Nombre)
			continue
		}
		paso(PasoOK, d.Nombre+": instalado.")
	}
	if len(fallos) > 0 {
		return fmt.Errorf("no se pudo instalar: %s", strings.Join(fallos, ", "))
	}
	paso(PasoAviso, "Si Windows lo pide, reinicia el equipo para que los controladores queden activos.")
	return nil
}

// bajaVerificado descarga url a destino y comprueba su SHA-256. Si no coincide
// borra el archivo: nunca se instala algo que no es lo que el catálogo describe.
func bajaVerificado(ctx context.Context, url, sha, destino string) error {
	if !strings.HasPrefix(strings.ToLower(url), "https://") {
		return fmt.Errorf("el enlace no es https")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "PCInfo")
	resp, err := clienteWeb.Do(req)
	if err != nil {
		return fmt.Errorf("no se pudo descargar: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("el servidor respondió HTTP %d", resp.StatusCode)
	}

	f, err := os.Create(destino)
	if err != nil {
		return err
	}
	h := sha256.New()
	total := resp.ContentLength
	var hecho, ultimoAviso int64
	buf := make([]byte, 256*1024)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			hecho += int64(n)
			if hecho > maxDescargaWeb {
				f.Close()
				os.Remove(destino)
				return fmt.Errorf("el archivo supera el tope de %d MB", maxDescargaWeb>>20)
			}
			h.Write(buf[:n])
			if _, werr := f.Write(buf[:n]); werr != nil {
				f.Close()
				os.Remove(destino)
				return werr
			}
			if total > 0 && hecho-ultimoAviso >= total/5 { // cada ~20 %
				ultimoAviso = hecho
				paso(PasoInfo, fmt.Sprintf("… %d %%", hecho*100/total))
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			f.Close()
			os.Remove(destino)
			if ctx.Err() != nil {
				return fmt.Errorf("la descarga se canceló")
			}
			return fmt.Errorf("se cortó la descarga: %w", rerr)
		}
	}
	if err := f.Close(); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); !strings.EqualFold(got, sha) {
		os.Remove(destino)
		return fmt.Errorf("el archivo descargado no coincide con el del catálogo (SHA-256 distinto): " +
			"el fabricante lo cambió o la descarga se alteró; no se instala")
	}
	return nil
}
