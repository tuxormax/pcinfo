//go:build linux

package collector

import (
	"os"
	"os/exec"
	"strings"
)

// Activar el diario permanente del sistema.
//
// En Mint y en Ubuntu journald guarda su diario en /run, es decir en memoria: se
// borra entero en cada apagado. Por eso de las sesiones anteriores solo consta a
// qué hora empezaron y terminaron, y nunca QUÉ pasó en ellas — que es justo lo
// que hace falta el día que el equipo no hizo lo que tenía que hacer.
//
// Basta con que exista /var/log/journal: journald lo detecta y empieza a
// escribir en disco. Se le pone además un tope de tamaño, porque el límite por
// defecto es el 10% de la partición y en un disco grande son varios gigabytes
// de registros que nadie va a leer.
const topeDiario = "500M"

func activaDiarioPersistente() ResultadoAccion {
	if journalPersistente() {
		return ResultadoAccion{
			Ok:      true,
			Message: "El diario del sistema ya se guarda en disco. No hay nada que cambiar.",
		}
	}
	script := `set -e
mkdir -p /var/log/journal
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/pcinfo-persistente.conf << 'EOF'
# Escrito por PCInfo: conserva el diario del sistema entre apagados.
# Sin esto, journald vive en memoria y cada apagado borra lo que pasó.
[Journal]
Storage=persistent
SystemMaxUse=` + topeDiario + `
EOF
systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
systemctl restart systemd-journald
echo LISTO
`
	salida, err := correComoRoot(script)
	if strings.Contains(salida, "LISTO") && journalPersistente() {
		return ResultadoAccion{
			Ok: true,
			Message: "Listo: el diario del sistema ya se guarda en disco (hasta " + topeDiario +
				"). Desde el próximo apagado quedará constancia de lo que pasó en cada sesión.",
		}
	}
	return ResultadoAccion{
		Ok: false,
		Message: "No se pudo activar el diario permanente. Hace falta la contraseña de " +
			"administrador; si se canceló el aviso, vuelve a intentarlo.",
		Detail: recorta(strings.TrimSpace(salida+" "+errTexto(err)), 500),
	}
}

// correComoRoot ejecuta un script con permisos de administrador. Si el backend
// ya corre como root lo hace directo; si no, lo pide con pkexec, que es el
// diálogo de contraseña del propio escritorio (no una ventana inventada por
// PCInfo, que es justo lo que nadie debería teclear su contraseña en).
func correComoRoot(script string) (string, error) {
	f, err := os.CreateTemp("", "pcinfo-*.sh")
	if err != nil {
		return "", err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(script); err != nil {
		return "", err
	}
	f.Close()
	if err := os.Chmod(f.Name(), 0o755); err != nil {
		return "", err
	}

	var cmd *exec.Cmd
	if isElevated() {
		cmd = exec.Command("bash", f.Name())
	} else {
		if _, err := exec.LookPath("pkexec"); err != nil {
			return "", err
		}
		cmd = exec.Command("pkexec", "bash", f.Name())
	}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func errTexto(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
