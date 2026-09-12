# Salidas reales de macOS (Mac mini M4, macOS 26.5.1) — 12-sep-2026

Capturas del equipo de pruebas del port a macOS. Sirven para escribir y probar
el parseo **sin necesidad de un Mac**: las pruebas unitarias corren igual en
Linux, que es donde vive el resto del proyecto.

⚠️ **Están ANONIMIZADAS a propósito.** Este repositorio es público, así que se
sustituyeron por ceros la serie del equipo, la del SSD, la del monitor, el
`platform_UUID`, el `provisioning_UDID`, los UUID de discos y volúmenes, y el
nombre del equipo. Todo lo demás es tal cual lo devolvió el sistema. Si vuelves
a capturar, **anonimiza igual antes de subir**.

| Archivo | Comando |
|---|---|
| `diskutil_list.plist` | `diskutil list -plist` |
| `diskutil_info_diskN.plist` | `diskutil info -plist diskN` |
| `diskutil_info_disk4_usb.plist` | igual, con el disco USB de 2 TB conectado (gabinete JMicron) |
| `smartctl_json_disk4_usb.json` | `smartctl --json=c -a /dev/disk4` — la respuesta de que **no se puede** |
| `smartctl_a_disk0.txt` · `smartctl_json_disk0.json` | `smartctl -a /dev/disk0` (con `--json=c`) |
| `smartctl_scan.txt` | `smartctl --scan` |
| `sp_SPHardwareDataType.json` · `sp_SPDisplaysDataType.json` | `system_profiler -json <tipo>` |
| `sw_vers.txt` · `uname.txt` · `sysctl_hw.txt` | los comandos del mismo nombre |

## Lo que estas capturas dejaron claro

- ⭐ **El SSD interno de un Apple Silicon SÍ da S.M.A.R.T.** por `/dev/disk0`, y
  **sin root**. Era la incógnita que decidía la pestaña Discos.
- `diskutil info -plist disk4` (disco USB) **se colgaba**: macOS estaba pidiendo
  un permiso de acceso al volumen que nadie contestó. De ahí que el colector
  llame a `diskutil` siempre con plazo.
- `diskutil info disk0 -plist` **falla**: el `-plist` va justo después del verbo.
- `diskutil` ya trae él mismo `SMARTStatus` y algunos atributos NVMe, por si
  algún día no se pudiera empaquetar `smartctl`.
- ⛔ **Por USB no hay salud en macOS y no es cosa de PCInfo**: `/dev/disk4`
  contesta *"Operation not supported by device"* y cada `-d <tipo>` responde
  *"Not a device of type 'scsi'"*. La documentación de smartmontools para Darwin
  lo dice: el soporte SCSI no está implementado y haría falta instalar el *SAT
  SMART Driver*. `diskutil` coincide: `SMARTStatus: Not Supported`.
- En un gabinete USB, `MediaName` llega **recortado** ("Tech") y el nombre
  completo está en `IORegistryEntryName` ("JMicron Tech Media").
- Un disco USB **puede no mandar `SolidState`**: eso es "no se sabe", no "no es
  SSD".
