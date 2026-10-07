<#
    errores_windows.ps1 — recolector del "Historial de Errores" de PCInfo (Windows).

    Lo ejecuta el backend Go (collector/errors_windows.go) y ESCRIBE UN JSON en la
    ruta -Salida; no imprime nada ni toca el sistema (solo LEE registros y .dmp).

    Fuentes:
      - Evento 1001 Microsoft-Windows-WER-SystemErrorReporting  → pantallazo azul (BSOD)
      - Evento 41   Microsoft-Windows-Kernel-Power (con BugcheckCode) → BSOD sin WER
      - Evento 6008 EventLog → apagado inesperado
      - <Raiz>\Minidump\*.dmp y <Raiz>\MEMORY.DMP → análisis del culpable
      - Registro System y Application, niveles Crítico(1) y Error(2) → resto de fallos

    -Raiz: carpeta de Windows a analizar. Por omisión la del sistema en ejecución.
    Si se pasa la de OTRA unidad (D:\Windows), el modo pasa a ser OFFLINE: los
    eventos ya no se piden al servicio de registro (ese Windows no está corriendo),
    sino que se leen DIRECTAMENTE de sus archivos .evtx. Sirve para diagnosticar
    desde un medio de rescate (Hiren's BootCD PE, WinPE) un equipo que ya no arranca.

    Comparte analizador con herramientas/bluescreen/bluescreen.ps1 (catálogo de STOP codes, guía en español y
    deducción del driver culpable a partir del volcado, sin herramientas externas).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Salida,
    [int]$Dias = 30,
    [int]$MaxEventos = 400,
    [string]$Raiz = ''
)

$ErrorActionPreference = 'Stop'
$desde = (Get-Date).AddDays(-$Dias)

# ==============================================================================
#  Instalación a analizar (la del sistema vivo o la de otra unidad)
# ==============================================================================
if ([string]::IsNullOrWhiteSpace($Raiz)) { $Raiz = $env:SystemRoot }
$Raiz = $Raiz.TrimEnd('\')
# OFFLINE = la carpeta pedida no es la del Windows que está corriendo.
$OFFLINE = -not ($Raiz -ieq ("$env:SystemRoot").TrimEnd('\'))
$LOGS = Join-Path $Raiz 'System32\winevt\Logs'

# ==============================================================================
#  Catálogo de STOP codes (nombre + causa/solución en español)
# ==============================================================================
$STOPCODES = @{
    '0x0000000A' = 'IRQL_NOT_LESS_OR_EQUAL'
    '0x0000001A' = 'MEMORY_MANAGEMENT'
    '0x0000001E' = 'KMODE_EXCEPTION_NOT_HANDLED'
    '0x00000022' = 'FILE_SYSTEM'
    '0x00000024' = 'NTFS_FILE_SYSTEM'
    '0x0000002E' = 'DATA_BUS_ERROR'
    '0x0000003B' = 'SYSTEM_SERVICE_EXCEPTION'
    '0x00000050' = 'PAGE_FAULT_IN_NONPAGED_AREA'
    '0x0000007A' = 'KERNEL_DATA_INPAGE_ERROR'
    '0x0000007B' = 'INACCESSIBLE_BOOT_DEVICE'
    '0x0000007E' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
    '0x0000007F' = 'UNEXPECTED_KERNEL_MODE_TRAP'
    '0x0000009F' = 'DRIVER_POWER_STATE_FAILURE'
    '0x000000A5' = 'ACPI_BIOS_ERROR'
    '0x000000A0' = 'INTERNAL_POWER_ERROR'
    '0x000000BE' = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY'
    '0x000000C2' = 'BAD_POOL_CALLER'
    '0x000000C4' = 'DRIVER_VERIFIER_DETECTED_VIOLATION'
    '0x000000C5' = 'DRIVER_CORRUPTED_EXPOOL'
    '0x000000CE' = 'DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS'
    '0x000000D1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
    '0x000000EF' = 'CRITICAL_PROCESS_DIED'
    '0x000000F4' = 'CRITICAL_OBJECT_TERMINATION'
    '0x000000FC' = 'ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY'
    '0x00000109' = 'CRITICAL_STRUCTURE_CORRUPTION'
    '0x00000116' = 'VIDEO_TDR_ERROR'
    '0x00000117' = 'VIDEO_TDR_TIMEOUT_DETECTED'
    '0x00000119' = 'VIDEO_SCHEDULER_INTERNAL_ERROR'
    '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR'
    '0x00000133' = 'DPC_WATCHDOG_VIOLATION'
    '0x00000139' = 'KERNEL_SECURITY_CHECK_FAILURE'
    '0x0000013A' = 'KERNEL_MODE_HEAP_CORRUPTION'
    '0x0000014C' = 'FATAL_UNHANDLED_HARD_ERROR'
    '0x00000154' = 'UNEXPECTED_STORE_EXCEPTION'
}

# Causa típica de cada STOP code (qué pasó y por qué).
$STOPCAUSA = @{
    '0x0000000A' = 'Un driver accedió a memoria con un nivel de interrupción (IRQL) demasiado alto. Casi siempre es un driver defectuoso o memoria RAM dañada.'
    '0x0000001A' = 'Error de administración de memoria: normalmente RAM dañada o un driver que corrompe la memoria del sistema.'
    '0x0000001E' = 'Un driver de modo kernel lanzó una excepción que nadie controló. Suele ser un driver de terceros recién instalado o desactualizado.'
    '0x00000022' = 'Fallo del sistema de archivos: el disco o su driver devolvieron datos inconsistentes.'
    '0x00000024' = 'Problema en el sistema de archivos NTFS: disco con sectores dañados o driver de almacenamiento defectuoso.'
    '0x0000002E' = 'Error de paridad en el bus de memoria: RAM defectuosa o mal asentada.'
    '0x000000A5' = 'El BIOS/UEFI entregó a Windows una tabla o un método ACPI defectuoso o incompleto. Es un problema de firmware (BIOS desactualizado o mal configurado), casi nunca de un driver.'
    '0x0000003B' = 'Una llamada al sistema falló dentro del kernel. Suele venir de un driver (gráfica, antivirus, virtualización).'
    '0x00000050' = 'Se accedió a una dirección de memoria que no existe. Sospechosos: RAM dañada, un driver o un antivirus.'
    '0x0000007A' = 'Windows no pudo leer del disco una página de memoria: disco, cable o controladora fallando.'
    '0x0000007B' = 'Windows no encuentra el disco de arranque: cambió el modo SATA (AHCI/RAID) en la BIOS o falta el driver de almacenamiento.'
    '0x0000007E' = 'Un hilo del sistema generó una excepción no controlada, provocada por un driver.'
    '0x0000007F' = 'Trampa inesperada del procesador: RAM defectuosa, overclock inestable o hardware fallando.'
    '0x0000009F' = 'Un driver quedó en un estado de energía inconsistente, típicamente al suspender o reanudar. Suele ser red, chipset o USB.'
    '0x000000A0' = 'Error interno del subsistema de energía, frecuente en portátiles con batería o firmware defectuoso.'
    '0x000000BE' = 'Un driver intentó escribir en memoria de solo lectura: driver defectuoso.'
    '0x000000C2' = 'Un driver hizo una operación inválida con la memoria del sistema (pool). Es un driver defectuoso.'
    '0x000000C4' = 'El Verificador de Controladores detectó que un driver viola las reglas del kernel.'
    '0x000000C5' = 'Un driver corrompió el pool de memoria del kernel.'
    '0x000000CE' = 'Un driver se descargó sin cancelar sus operaciones pendientes.'
    '0x000000D1' = 'Un driver accedió a memoria inválida con IRQL alto. Muy común en drivers de red/WiFi y de tarjeta gráfica.'
    '0x000000EF' = 'Murió un proceso crítico de Windows: corrupción del sistema, un driver o malware.'
    '0x000000F4' = 'Terminó un objeto crítico del sistema: casi siempre el DISCO (SSD/HDD) o su controladora fallando.'
    '0x000000FC' = 'Se intentó ejecutar código en memoria no ejecutable: driver defectuoso.'
    '0x00000109' = 'Windows detectó que se modificó una estructura crítica del kernel: driver defectuoso, overclock o malware.'
    '0x00000116' = 'El driver de video no respondió y no se pudo recuperar (TDR).'
    '0x00000117' = 'El driver de video se colgó y no respondió a tiempo (TDR).'
    '0x00000119' = 'Error interno del planificador de video: driver de la tarjeta gráfica defectuoso.'
    '0x00000124' = 'Error de HARDWARE reportado por el propio procesador (WHEA): CPU, RAM, sobrecalentamiento o fuente de poder. NO es un driver.'
    '0x00000133' = 'Un driver mantuvo la CPU ocupada demasiado tiempo. Muy común con controladoras de almacenamiento o SSD con firmware viejo.'
    '0x00000139' = 'Windows detectó corrupción en una estructura de seguridad del kernel: driver defectuoso o malware.'
    '0x0000013A' = 'Corrupción del heap del kernel, causada por un driver.'
    '0x0000014C' = 'Error grave no controlado del sistema: componentes de Windows dañados.'
    '0x00000154' = 'Excepción inesperada del almacenamiento: SSD/HDD fallando o con firmware antiguo.'
}

# Qué hacer para resolverlo.
$STOPFIX = @{
    '0x0000000A' = 'Actualiza o revierte el driver señalado abajo y corre el Diagnóstico de memoria de Windows (mdsched.exe).'
    '0x0000001A' = 'Corre mdsched.exe (test de RAM) y actualiza los drivers de chipset y almacenamiento.'
    '0x0000001E' = 'Desinstala o actualiza el driver de terceros señalado abajo; si fue tras instalar algo, revierte ese cambio.'
    '0x00000022' = 'Corre "chkdsk C: /f /r" y revisa la salud del disco en la pestaña Hardware.'
    '0x00000024' = 'Corre "chkdsk C: /f /r", revisa el S.M.A.R.T. del disco y cambia el cable SATA.'
    '0x0000002E' = 'Prueba la RAM con mdsched.exe o memtest86+, y reasienta los módulos.'
    '0x000000A5' = 'Actualiza el BIOS/UEFI desde la página del fabricante, carga los valores por defecto del BIOS, instala el chipset y el audio oficiales del equipo y, si falla al reanudar, desactiva la suspensión. Anota el 1er parámetro del código: dice qué tipo de fallo ACPI fue.'
    '0x0000003B' = 'Actualiza el driver de la gráfica y desinstala antivirus de terceros temporalmente para descartar.'
    '0x00000050' = 'Corre mdsched.exe (test de RAM); si la RAM está bien, actualiza o desinstala el driver señalado.'
    '0x0000007A' = 'Revisa el S.M.A.R.T. del disco en la pestaña Hardware, cambia el cable SATA y corre "chkdsk C: /f /r".'
    '0x0000007B' = 'Entra a la BIOS y revisa el modo del controlador SATA (AHCI/RAID); instala el driver de almacenamiento correcto.'
    '0x0000007E' = 'Actualiza o revierte el driver de terceros señalado abajo.'
    '0x0000007F' = 'Quita cualquier overclock/XMP, prueba la RAM con memtest86+ y revisa temperaturas.'
    '0x0000009F' = 'Actualiza los drivers de red, chipset y USB; desactiva la suspensión selectiva de USB en Opciones de energía.'
    '0x000000A0' = 'Actualiza la BIOS/UEFI y los drivers de chipset; en portátiles, revisa la batería.'
    '0x000000BE' = 'Identifica el driver señalado abajo y actualízalo o desinstálalo.'
    '0x000000C2' = 'Actualiza el driver de terceros señalado abajo; si fue tras instalar un programa con driver, desinstálalo.'
    '0x000000C4' = 'Desactiva el Verificador de Controladores con "verifier /reset" y actualiza el driver señalado.'
    '0x000000C5' = 'Actualiza el driver señalado abajo y corre "sfc /scannow".'
    '0x000000CE' = 'Actualiza o desinstala el driver señalado abajo.'
    '0x000000D1' = 'Actualiza o revierte el driver señalado abajo (revisa primero red/WiFi y tarjeta gráfica).'
    '0x000000EF' = 'Corre "sfc /scannow" y luego "DISM /Online /Cleanup-Image /RestoreHealth"; haz un análisis de malware.'
    '0x000000F4' = 'Revisa el S.M.A.R.T. del disco en la pestaña Hardware, cambia el cable SATA y actualiza el firmware del SSD.'
    '0x000000FC' = 'Actualiza el driver señalado abajo.'
    '0x00000109' = 'Quita el overclock, corre "sfc /scannow" y haz un análisis de malware.'
    '0x00000116' = 'Reinstala en limpio el driver de la tarjeta gráfica (DDU) y revisa su temperatura y alimentación.'
    '0x00000117' = 'Reinstala el driver de la gráfica y limpia el polvo de la tarjeta; revisa la fuente de poder.'
    '0x00000119' = 'Reinstala el driver de la tarjeta gráfica en limpio.'
    '0x00000124' = 'Revisa temperaturas, limpia el equipo, quita el overclock, prueba la RAM con memtest86+ y verifica la fuente de poder.'
    '0x00000133' = 'Actualiza el firmware del SSD y los drivers de almacenamiento/chipset (iaStor, stornvme).'
    '0x00000139' = 'Actualiza el driver señalado abajo, corre "sfc /scannow" y haz un análisis de malware.'
    '0x0000013A' = 'Identifica el driver de terceros señalado abajo y actualízalo.'
    '0x0000014C' = 'Corre "sfc /scannow" y "DISM /Online /Cleanup-Image /RestoreHealth".'
    '0x00000154' = 'Revisa el S.M.A.R.T. del disco, actualiza el firmware del SSD y los drivers de almacenamiento.'
}

function Normaliza-Stop([string]$hex) {
    if ([string]::IsNullOrWhiteSpace($hex)) { return '' }
    $k = $hex.Trim().ToLower()
    if ($k -notlike '0x*') { $k = '0x' + $k }
    $num = $k.Substring(2).TrimStart('0')
    if ($num -eq '') { $num = '0' }
    return '0x' + $num.PadLeft(8, '0').ToUpper()
}

function Nombre-Stop([string]$hex) {
    $full = Normaliza-Stop $hex
    if ($full -and $STOPCODES.ContainsKey($full)) { return $STOPCODES[$full] }
    return ''
}

function Causa-Stop([string]$hex) {
    $full = Normaliza-Stop $hex
    if ($full -and $STOPCAUSA.ContainsKey($full)) { return $STOPCAUSA[$full] }
    return 'Windows detuvo el equipo para no dañar los datos. Este codigo no esta en el catalogo de PCInfo: si abajo aparece un driver de terceros, ese es el sospechoso principal; si no, sospecha del hardware (RAM, disco o temperatura).'
}

function Fix-Stop([string]$hex) {
    $full = Normaliza-Stop $hex
    if ($full -and $STOPFIX.ContainsKey($full)) { return $STOPFIX[$full] }
    return 'Actualiza los drivers de terceros listados abajo (empieza por el mas reciente que hayas instalado). Si no hay ninguno, prueba la RAM con mdsched.exe y revisa la salud del disco en la pestana Hardware.'
}

# Clase de hardware sospechosa según el bugcheck, para priorizar al culpable.
function Clase-Bugcheck([string]$hex) {
    $full = Normaliza-Stop $hex
    if (-not $full) { return '' }
    switch ($full) {
        '0x00000116' { 'video' } '0x00000117' { 'video' } '0x00000119' { 'video' } '0x000000EA' { 'video' }
        '0x0000007A' { 'disco' } '0x0000007B' { 'disco' } '0x000000F4' { 'disco' } '0x00000154' { 'disco' } '0x00000133' { 'disco' }
        '0x000000D1' { 'red' }   '0x0000009F' { 'red' }
        default { '' }
    }
}
$CLASE_HINTS = @{
    video = @('nvlddmkm', 'atikm', 'amdkm', 'amdgpu', 'igdkmd', 'igfx', 'nvhda', 'radeon')
    disco = @('iastor', 'stornvme', 'storahci', 'storport', 'nvme', 'amdsata', 'amdxata', 'rst', 'samsung', 'crucial')
    red   = @('netwtw', 'netwbw', 'netwlv', 'athw', 'rtwlan', 'rtl', 'e1', 'bcm', 'mrvl', 'vwifi', 'netr', 'rtux', 'athr', 'killer')
}

# ==============================================================================
#  Análisis del volcado (.dmp) sin herramientas externas
# ==============================================================================

function Get-DriverInfo([string]$nombre) {
    # Los drivers se buscan en la instalación ANALIZADA: en modo offline lo que
    # interesa es el driver del equipo averiado, no el del medio de rescate.
    $dirs = @("$Raiz\System32\drivers", "$Raiz\System32", "$Raiz\SysWOW64", "$Raiz")
    foreach ($d in $dirs) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $p = Join-Path $d $nombre
        if (Test-Path $p) {
            try {
                $vi = (Get-Item $p).VersionInfo
                return [pscustomobject]@{
                    Nombre      = $nombre
                    Ruta        = $p
                    Compania    = ("$($vi.CompanyName)").Trim()
                    Version     = ("$($vi.FileVersion)").Trim()
                    Descripcion = ("$($vi.FileDescription)").Trim()
                }
            } catch { }
        }
    }
    return $null
}

# Lee como máximo $max bytes del archivo (MEMORY.DMP puede pesar varios GB).
function Lee-Bytes([string]$ruta, [int]$max) {
    $fs = [System.IO.File]::Open($ruta, 'Open', 'Read', 'ReadWrite')
    try {
        $n = [int][Math]::Min([int64]$max, $fs.Length)
        $buf = New-Object byte[] $n
        [void]$fs.Read($buf, 0, $n)
        return $buf
    } finally { $fs.Dispose() }
}

# =============================================================================
#  LECTURA REAL DEL VOLCADO  (v1.7)
# -----------------------------------------------------------------------------
#  Antes, el culpable se elegia buscando en el archivo CUALQUIER cadena que
#  pareciera un nombre de driver (regex sobre los bytes) y quedandose con el
#  primero que no fuera de Microsoft. Eso no distingue entre "este driver estaba
#  ejecutandose cuando revento" y "este nombre aparece suelto en algun lado del
#  archivo", y por eso acusaba a drivers que ni siquiera estan cargados.
#
#  Caso real (25-ago-2026): senalo adp80xx.sys (controladora SAS de
#  PMC-Sierra) en una laptop ASUS que no tiene esa controladora ni ese driver
#  cargado. El culpable de verdad era atc.sys, de Bitdefender, y estaba SEIS
#  veces en la pila de llamadas.
#
#  Ahora se leen las estructuras que el propio volcado trae:
#
#    - LISTA DE MODULOS: cada driver con su direccion base y su tamano. Con eso
#      cualquier direccion se traduce a "modulo+desplazamiento".
#    - PILA DE LLAMADAS: se traduce cada direccion. Un driver que aparece aqui
#      ESTABA EJECUTANDOSE. Eso es prueba, no sospecha.
#    - DRIVERS DESCARGADOS: los que Windows acababa de descargar, CON SU RANGO
#      DE DIRECCIONES. Si la direccion que fallo cae en el rango de uno de
#      ellos, es la prueba definitiva del clasico "driver que se descargo y
#      dejo enganches vivos apuntando a memoria liberada".
#
#  Solo los MINIDUMPS traen estas estructuras (DumpType = 4, "triage"). Un
#  MEMORY.DMP completo no las tiene: ahi se sigue usando el metodo viejo, pero
#  marcado como confianza BAJA para que no se confunda con una prueba.
# =============================================================================

# Offsets del formato PAGEDU64. La cabecera del volcado ocupa 0x2000 bytes y
# justo despues viene la cabecera "triage" con 18 enteros de 32 bits.
$TRIAGE_BASE = 0x2000
$TRIAGE_CAMPOS = @{
    UnloadedDriversOffset =  6
    CallStackOffset       = 10
    SizeOfCallStack       = 11
    DriverListOffset      = 12
    DriverCount           = 13
}
# Cada entrada de la lista de drivers mide 0x90 bytes.
$DRV_STRIDE   = 0x90
$DRV_NOMBREOF = 0x00   # desplazamiento (absoluto en el archivo) al nombre
$DRV_BASE     = 0x38   # DllBase
$DRV_TAM      = 0x48   # SizeOfImage
# Cada entrada de descargados mide 0x38, tras un contador de 64 bits.
$UNL_STRIDE   = 0x38
$UNL_NOMBRE   = 0x10   # el nombre va EN LINEA, maximo 12 caracteres
$UNL_INICIO   = 0x28
$UNL_FIN      = 0x30

function Lee-U32($b, $o) {
    if ($o -lt 0 -or ($o + 4) -gt $b.Length) { return $null }
    return [BitConverter]::ToUInt32($b, $o)
}
function Lee-U64($b, $o) {
    if ($o -lt 0 -or ($o + 8) -gt $b.Length) { return $null }
    return [BitConverter]::ToUInt64($b, $o)
}

# Lee las estructuras del minidump. Devuelve $null si el volcado no es "triage"
# o si algo no cuadra: ante la duda NO se inventa nada, se cae al metodo viejo.
function Lee-Triage($b) {
    $tipo = Lee-U32 $b 0xF98
    if ($tipo -ne 4) { return $null }   # 4 = DUMP_TYPE_TRIAGE (minidump)

    $h = @{}
    foreach ($k in $TRIAGE_CAMPOS.Keys) {
        $v = Lee-U32 $b ($TRIAGE_BASE + 4 * $TRIAGE_CAMPOS[$k])
        if ($null -eq $v) { return $null }
        $h[$k] = [int]$v
    }
    # Coherencia: un minidump real tiene unos cientos de drivers, no millones.
    if ($h.DriverCount -le 0 -or $h.DriverCount -gt 5000) { return $null }
    if (($h.DriverListOffset + $h.DriverCount * $DRV_STRIDE) -gt $b.Length) { return $null }

    # --- Lista de modulos cargados -----------------------------------------
    $mods = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $h.DriverCount; $i++) {
        $e   = $h.DriverListOffset + $i * $DRV_STRIDE
        $no  = Lee-U64 $b ($e + $DRV_NOMBREOF)
        $bas = Lee-U64 $b ($e + $DRV_BASE)
        $tam = Lee-U32 $b ($e + $DRV_TAM)
        if ($null -eq $no -or $null -eq $bas -or $null -eq $tam) { continue }
        if ($bas -eq 0 -or $tam -eq 0) { continue }
        $nombre = Lee-NombreW $b ([int]$no)
        if (-not $nombre) { continue }
        [void]$mods.Add([pscustomobject]@{
            Nombre = [System.IO.Path]::GetFileName($nombre.Replace('\', '/'))
            Base   = $bas
            Fin    = $bas + $tam
        })
    }
    if ($mods.Count -eq 0) { return $null }

    # --- Drivers descargados, con su rango ---------------------------------
    # OJO: Windows guarda el nombre RECORTADO a 12 caracteres en esta lista
    # ("bdprivmon.sy"). No es un fallo de lectura: es como lo almacena.
    $desc = New-Object System.Collections.ArrayList
    $uo = $h.UnloadedDriversOffset
    $cnt = Lee-U64 $b $uo
    if ($null -ne $cnt -and $cnt -gt 0 -and $cnt -le 64) {
        for ($i = 0; $i -lt $cnt; $i++) {
            $e = $uo + 8 + $i * $UNL_STRIDE
            if (($e + $UNL_STRIDE) -gt $b.Length) { break }
            $ln = [BitConverter]::ToUInt16($b, $e)
            if ($ln -le 0 -or $ln -gt 24) { continue }
            $nm = [System.Text.Encoding]::Unicode.GetString($b, $e + $UNL_NOMBRE, $ln).Trim([char]0)
            if (-not $nm) { continue }
            [void]$desc.Add([pscustomobject]@{
                Nombre = $nm
                Base   = (Lee-U64 $b ($e + $UNL_INICIO))
                Fin    = (Lee-U64 $b ($e + $UNL_FIN))
            })
        }
    }

    # --- Pila de llamadas ---------------------------------------------------
    # Se recorre de 8 en 8 bytes traduciendo cada valor. Los que caen dentro de
    # un modulo son direcciones de retorno: ahi estuvo la ejecucion.
    $pila = New-Object System.Collections.ArrayList
    $cs = $h.CallStackOffset; $sz = $h.SizeOfCallStack
    if ($cs -gt 0 -and $sz -gt 0 -and ($cs + $sz) -le $b.Length) {
        $ultimo = ''
        for ($o = 0; $o -lt ($sz - 8); $o += 8) {
            $v = Lee-U64 $b ($cs + $o)
            if ($null -eq $v) { break }
            $m = Halla-Modulo $mods $v
            # Se agrupan repeticiones seguidas: el mismo modulo 30 veces
            # seguidas es una sola llamada, no 30 pasos distintos.
            if ($m -and $m.Nombre -ne $ultimo) {
                [void]$pila.Add($m.Nombre)
                $ultimo = $m.Nombre
            }
        }
    }

    return [pscustomobject]@{ Modulos = $mods; Descargados = $desc; Pila = $pila }
}

# Nombre en UTF-16 precedido de su longitud en caracteres (32 bits).
function Lee-NombreW($b, $o) {
    $n = Lee-U32 $b $o
    if ($null -eq $n -or $n -le 0 -or $n -gt 260) { return '' }
    $bytes = $n * 2
    if (($o + 4 + $bytes) -gt $b.Length) { return '' }
    return [System.Text.Encoding]::Unicode.GetString($b, $o + 4, $bytes).Trim([char]0)
}

function Halla-Modulo($mods, $dir) {
    if ($null -eq $dir -or $dir -eq 0) { return $null }
    foreach ($m in $mods) {
        if ($dir -ge $m.Base -and $dir -lt $m.Fin) { return $m }
    }
    return $null
}

function Es-DeMicrosoft($info) {
    if (-not $info) { return $false }
    return ($info.Compania -and $info.Compania -match 'Microsoft')
}

function Analiza-Dump($archivoDump, $stopEvento) {
    $res = [pscustomobject]@{
        Archivo = $archivoDump.FullName; Formato = ''; Stop = $stopEvento; FaultAddr = ''
        Culpable = $null; Confianza = 'baja'; Sospechosos = @(); Evidencia = @()
        Pila = @(); Descargados = @(); Nota = ''
    }
    # 16 MB basta: un minidump completo pesa mucho menos y de MEMORY.DMP (que
    # puede ocupar GB) la lista de modulos vive al principio. Leer mas haria que
    # la busqueda de modulos tardara minutos.
    try { $bytes = Lee-Bytes $archivoDump.FullName (16MB) }
    catch { $res.Nota = "No se pudo leer el volcado: $($_.Exception.Message)"; return $res }
    if ($bytes.Length -lt 0x1000) { $res.Nota = 'El volcado esta incompleto o es demasiado pequeno.'; return $res }

    $params = @()
    $sig = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8)
    if ($sig -like 'PAGEDU64*') {
        $res.Formato = 'Kernel x64 (PAGEDU64)'
        try {
            $bc = [BitConverter]::ToUInt32($bytes, 0x38)
            if ($bc -ne 0 -and -not $res.Stop) { $res.Stop = '0x' + $bc.ToString('X8') }
            # Los 4 parametros del bugcheck viven en 0x40, 0x48, 0x50 y 0x58.
            for ($i = 0; $i -lt 4; $i++) {
                $v = Lee-U64 $bytes (0x40 + 8 * $i)
                if ($null -ne $v) { $params += $v }
            }
            if ($bytes.Length -ge 0xF18) {
                $ex = [BitConverter]::ToUInt64($bytes, 0xF10)
                if ($ex -ne 0) { $res.FaultAddr = '0x' + $ex.ToString('X16') }
            }
        } catch { }
    } elseif ($sig -like 'PAGEDUMP*') {
        $res.Formato = 'Kernel x86 (PAGEDUMP)'
        try { $bc = [BitConverter]::ToUInt32($bytes, 0x38); if ($bc -ne 0 -and -not $res.Stop) { $res.Stop = '0x' + $bc.ToString('X8') } } catch { }
    } elseif ($sig -like 'MDMP*') {
        $res.Formato = 'Minidump estandar (MDMP)'
    } else {
        $res.Formato = 'Formato desconocido'
    }

    $clase = Clase-Bugcheck $res.Stop
    $tri = $null
    try { $tri = Lee-Triage $bytes } catch { $tri = $null }

    # ================= CAMINO BUENO: estructuras reales del volcado ==========
    if ($tri) {
        $res.Formato = $res.Formato + ' - estructuras leidas'
        $res.Pila = @($tri.Pila)
        $res.Descargados = @($tri.Descargados | ForEach-Object { $_.Nombre })

        # --- Prueba 1: drivers de TERCEROS en la pila de llamadas -----------
        # Si un driver aparece aqui es porque SU CODIGO se estaba ejecutando.
        $enPila = New-Object System.Collections.ArrayList
        foreach ($nm in $tri.Pila) {
            $info = Get-DriverInfo $nm
            if ($info -and -not (Es-DeMicrosoft $info)) {
                if (-not ($enPila | Where-Object { $_.Nombre -eq $info.Nombre })) { [void]$enPila.Add($info) }
            }
        }

        # --- Prueba 2: la direccion que fallo cae en un driver DESCARGADO ---
        # Es el clasico "se descargo dejando enganches vivos": la siguiente
        # operacion salta a memoria que ya no es de nadie.
        $culpableDescargado = $null
        foreach ($p in $params) {
            foreach ($d in $tri.Descargados) {
                if ($null -ne $d.Base -and $null -ne $d.Fin -and $p -ge $d.Base -and $p -lt $d.Fin) {
                    $culpableDescargado = $d; break
                }
            }
            if ($culpableDescargado) { break }
        }

        if ($culpableDescargado) {
            $info = Get-DriverInfo $culpableDescargado.Nombre
            if (-not $info) { $info = [pscustomobject]@{ Nombre = $culpableDescargado.Nombre; Ruta = ''; Compania = ''; Version = ''; Descripcion = '' } }
            $res.Culpable = $info
            $res.Confianza = 'alta'
            $res.Sospechosos = @($info) + @($enPila)
            $res.Evidencia = @("La direccion que fallo cae dentro de '$($culpableDescargado.Nombre)', un driver que Windows ACABABA DE DESCARGAR. Se descargo dejando trabajo pendiente apuntando a memoria ya liberada.")
        }
        elseif ($enPila.Count -gt 0) {
            # Si hay pista por clase de bugcheck (video/disco/red), se prefiere
            # ese; si no, el que este mas arriba en la pila.
            $orden = $enPila
            if ($clase -and $CLASE_HINTS.ContainsKey($clase)) {
                $hints = $CLASE_HINTS[$clase]
                $pref = @($enPila | Where-Object { $nm = $_.Nombre; ($hints | Where-Object { $nm -like "*$_*" }).Count -gt 0 })
                $orden = @($pref) + @($enPila | Where-Object { $pref -notcontains $_ })
            }
            $res.Culpable = $orden[0]
            $res.Confianza = 'alta'
            $res.Sospechosos = @($orden)
            $veces = @($tri.Pila | Where-Object { $_ -eq $orden[0].Nombre }).Count
            $res.Evidencia = @("'$($orden[0].Nombre)' aparece $veces $(if($veces -eq 1){'vez'}else{'veces'}) en la pila de llamadas del volcado: su codigo se estaba ejecutando cuando el equipo cayo.")
        }
        else {
            # NINGUN driver de terceros en la pila. Antes aqui se inventaba un
            # culpable a partir de cualquier nombre suelto del archivo; ahora se
            # dice la verdad, que es un dato util por si mismo.
            $res.Confianza = 'baja'
            $pilaTxt = if ($tri.Pila.Count -gt 0) { ($tri.Pila | Select-Object -First 6) -join ' -> ' } else { '(vacia)' }
            $res.Nota = "En la pila de llamadas de este volcado NO hay ningun driver de terceros: solo componentes de Windows ($pilaTxt). No se puede senalar a un driver con este volcado."
            if ($tri.Descargados.Count -gt 0) {
                $res.Nota += " Windows estaba descargando estos drivers al momento de la caida: $((@($tri.Descargados | ForEach-Object { $_.Nombre }) | Select-Object -First 8) -join ', ')."
            }
            # Los cargados de terceros quedan como sospechosos SIN acusar a nadie.
            $sos = New-Object System.Collections.ArrayList
            foreach ($m in $tri.Modulos) {
                $info = Get-DriverInfo $m.Nombre
                if ($info -and -not (Es-DeMicrosoft $info)) {
                    if ($clase -and $CLASE_HINTS.ContainsKey($clase)) {
                        $nm = $info.Nombre
                        if (($CLASE_HINTS[$clase] | Where-Object { $nm -like "*$_*" }).Count -gt 0) { [void]$sos.Add($info) }
                    }
                }
            }
            $res.Sospechosos = @($sos)
            if ($sos.Count -gt 0) {
                $res.Evidencia = @("Ninguno estaba en la pila. Se listan por ser drivers de $clase y este pantallazo ser de $clase, que es una coincidencia de categoria, NO una prueba.")
            }
        }
        return $res
    }

    # ============ CAMINO DE RESPALDO: volcado sin estructuras ================
    # MEMORY.DMP completo, minidump x86 o MDMP. Aqui solo se puede mirar que
    # nombres aparecen en el archivo, que es justo el metodo que producia falsos
    # positivos. Se conserva porque es mejor que nada, pero se marca BAJA y se
    # dice en la nota para que nadie lo tome por una prueba.
    $rx = [regex]'(?i)\b[a-z0-9_\-]{2,40}\.(sys|dll|exe)\b'
    $nombres = New-Object System.Collections.Generic.HashSet[string]
    foreach ($enc in @([System.Text.Encoding]::ASCII, [System.Text.Encoding]::Unicode)) {
        $txt = $enc.GetString($bytes)
        foreach ($m in $rx.Matches($txt)) { [void]$nombres.Add($m.Value.ToLower()) }
    }
    $terceros = @()
    foreach ($n in $nombres) {
        $info = Get-DriverInfo $n
        if ($info -and -not (Es-DeMicrosoft $info)) { $terceros += $info }
    }
    $terceros = @($terceros | Sort-Object Nombre -Unique)

    # Sin pista de categoria no se acusa a nadie: seria elegir al azar.
    if ($clase -and $CLASE_HINTS.ContainsKey($clase)) {
        $hints = $CLASE_HINTS[$clase]
        $pref = @($terceros | Where-Object { $nm = $_.Nombre; ($hints | Where-Object { $nm -like "*$_*" }).Count -gt 0 })
        if ($pref.Count -gt 0) {
            $res.Culpable = $pref[0]
            $res.Confianza = 'baja'
            $res.Sospechosos = @($pref) + @($terceros | Where-Object { $pref -notcontains $_ })
            $res.Evidencia = @("Este volcado no trae la lista de modulos ni la pila, asi que NO hay prueba de que este driver interviniera: solo aparece nombrado en el archivo y es de $clase, como el pantallazo. Trata esto como una pista, no como un diagnostico.")
            $res.Nota = 'Volcado sin estructuras de diagnostico. Para un analisis fiable hace falta un minidump de C:\Windows\Minidump.'
            return $res
        }
    }
    $res.Sospechosos = @($terceros | Select-Object -First 10)
    if ($terceros.Count -gt 0) {
        $res.Nota = 'Este volcado no trae la lista de modulos ni la pila de llamadas, asi que no se puede senalar a nadie. Los drivers de terceros listados solo aparecen nombrados dentro del archivo, que no prueba que hayan intervenido.'
    } else {
        $res.Nota = 'No se hallaron drivers de terceros en el volcado: el causante probable es un componente de Windows, y la causa de fondo suele ser hardware (RAM, disco o temperatura) o Windows danado.'
    }
    return $res
}

function Get-Minidumps {
    $dumps = @()
    foreach ($r in @("$Raiz\Minidump", "$Raiz")) {
        if (Test-Path $r) {
            try {
                $dumps += Get-ChildItem -Path $r -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\Temp\\' }
            } catch { }
        }
    }
    return @($dumps | Sort-Object LastWriteTime -Descending)
}

function Buscar-Dump($cuando, $rutaDump, $dumps) {
    # La ruta que anoto Windows es la SUYA ("C:\Windows\Minidump\...", con la
    # letra que tenia al fallar). Vista desde el medio de rescate esa unidad puede
    # ser otra letra, asi que se traduce a la raiz que se esta analizando.
    if ($rutaDump -and $OFFLINE -and ($rutaDump -match '(?i)^[A-Z]:\\Windows\\(.+)$')) {
        $rutaDump = Join-Path $Raiz $Matches[1]
    }
    if ($rutaDump -and (Test-Path $rutaDump)) { return Get-Item $rutaDump }
    if (-not $dumps -or $dumps.Count -eq 0) { return $null }
    $best = $null; $bestDiff = [double]::MaxValue
    foreach ($d in $dumps) {
        $diff = [math]::Abs(($d.LastWriteTime - $cuando).TotalMinutes)
        if ($diff -lt $bestDiff) { $bestDiff = $diff; $best = $d }
    }
    if ($best -and $bestDiff -le 20) { return $best }
    return $null
}

# ==============================================================================
#  Catálogo de eventos del registro (proveedor|Id → causa y solución)
# ==============================================================================
# kind: pantallazo | apagado | hardware | disco | grafica | servicio | aplicacion | memoria | sistema
$EVENTOS = @{
    'EventLog|6008'                                = @{ kind = 'apagado'; sev = 'error'; titulo = 'El equipo se apagó de forma inesperada'
        causa = 'Windows arrancó y detectó que la sesión anterior no se cerró bien: corte de luz, apagado forzado con el botón, un cuelgue total o un pantallazo azul que no alcanzó a registrarse.'
        fix = 'Si no fue un apagado a mano, revisa la fuente de poder y los cables de corriente, y busca en esta misma lista si hubo un error de hardware justo antes de esta hora.'
    }
    'Microsoft-Windows-Kernel-Power|41'            = @{ kind = 'apagado'; sev = 'critico'; titulo = 'El sistema se reinició sin apagarse correctamente'
        causa = 'El kernel no tuvo tiempo de cerrar la sesión: pantallazo azul, corte de energía, sobrecalentamiento o una fuente de poder que no da abasto.'
        fix = 'Revisa temperaturas y limpia el equipo; prueba con otra fuente/regulador. Si el evento trae un código de bugcheck, es un pantallazo azul: revisa esa entrada. Con código 0 puede ser un pantallazo que no alcanzó a guardar su volcado (pasa con errores al arrancar o al reanudar, como ACPI_BIOS_ERROR): mira el aviso sobre volcados.'
    }
    'Microsoft-Windows-WHEA-Logger|17'             = @{ kind = 'hardware'; sev = 'aviso'; titulo = 'Error de hardware corregido automáticamente (WHEA)'
        causa = 'El hardware detectó un error y pudo corregirlo solo. Es un aviso temprano: memoria, bus PCIe o CPU empezando a dar problemas.'
        fix = 'Vigílalo. Si se repite seguido, prueba la RAM con mdsched.exe, reasienta tarjetas y módulos, actualiza la BIOS y revisa temperaturas.'
    }
    'Microsoft-Windows-WHEA-Logger|18'             = @{ kind = 'hardware'; sev = 'critico'; titulo = 'Error de hardware NO corregible (WHEA)'
        causa = 'El procesador reportó un error físico que no se pudo corregir: RAM defectuosa, CPU dañada, sobrecalentamiento o fuente de poder inestable.'
        fix = 'Quita cualquier overclock/XMP, prueba la RAM con memtest86+, limpia disipadores y revisa la fuente de poder. Es hardware, no software.'
    }
    'Microsoft-Windows-WHEA-Logger|19'             = @{ kind = 'hardware'; sev = 'aviso'; titulo = 'Error de hardware corregido en la caché/memoria (WHEA)'
        causa = 'El sistema corrigió un error de memoria o de caché del procesador.'
        fix = 'Si aparece con frecuencia, prueba la RAM y revisa temperaturas y voltajes.'
    }
    'Microsoft-Windows-WHEA-Logger|47'             = @{ kind = 'hardware'; sev = 'aviso'; titulo = 'Errores de memoria corregidos repetidamente (WHEA)'
        causa = 'Un módulo de RAM está acumulando errores corregibles: suele anunciar una falla próxima.'
        fix = 'Prueba la RAM con memtest86+ módulo por módulo y reemplaza el que falle.'
    }
    'disk|7'                                       = @{ kind = 'disco'; sev = 'critico'; titulo = 'El dispositivo tiene un bloque defectuoso'
        causa = 'El disco no pudo leer o escribir en una zona física: hay sectores dañados.'
        fix = 'RESPALDA tus datos, revisa el S.M.A.R.T. en la pestaña Hardware y corre "chkdsk C: /f /r". Si hay sectores reasignados, reemplaza el disco.'
    }
    'disk|11'                                      = @{ kind = 'disco'; sev = 'error'; titulo = 'Error del controlador de disco'
        causa = 'La controladora reportó un error al comunicarse con la unidad: cable SATA/USB en mal estado, disco fallando o puerto defectuoso.'
        fix = 'Cambia el cable SATA/USB y prueba otro puerto; revisa el S.M.A.R.T. del disco en la pestaña Hardware.'
    }
    'disk|51'                                      = @{ kind = 'disco'; sev = 'error'; titulo = 'Error al escribir en el disco (paginación)'
        causa = 'Windows falló al escribir en el disco durante una operación de paginación: cable, disco o alimentación con problemas.'
        fix = 'Cambia el cable, revisa el S.M.A.R.T. y corre "chkdsk C: /f /r".'
    }
    'disk|153'                                     = @{ kind = 'disco'; sev = 'aviso'; titulo = 'La operación de E/S se reintentó'
        causa = 'El disco tardó demasiado y Windows tuvo que reintentar. Típico de discos externos USB o unidades que empiezan a fallar.'
        fix = 'Cambia el cable/puerto USB; si es interno, revisa el S.M.A.R.T. en la pestaña Hardware.'
    }
    'Ntfs|55'                                      = @{ kind = 'disco'; sev = 'critico'; titulo = 'Estructura del sistema de archivos NTFS dañada'
        causa = 'NTFS detectó corrupción en la partición: apagones, apagados forzados o disco con sectores dañados.'
        fix = 'Corre "chkdsk C: /f /r" y reinicia. Después revisa el S.M.A.R.T. del disco: si está dañado, reemplázalo.'
    }
    'Ntfs|98'                                      = @{ kind = 'disco'; sev = 'error'; titulo = 'NTFS detectó una inconsistencia'
        causa = 'Se encontraron metadatos inconsistentes en el volumen.'
        fix = 'Corre "chkdsk C: /f /r" y revisa la salud del disco.'
    }
    'Ntfs|137'                                     = @{ kind = 'disco'; sev = 'error'; titulo = 'El volumen no pudo escribirse (transacción NTFS)'
        causa = 'Una operación del sistema de archivos no se pudo completar, normalmente por errores del disco.'
        fix = 'Corre "chkdsk C: /f /r" y revisa el S.M.A.R.T. del disco.'
    }
    'volmgr|161'                                   = @{ kind = 'sistema'; sev = 'aviso'; titulo = 'No se pudo generar el volcado de memoria del pantallazo'
        causa = 'Windows quiso guardar el archivo .dmp del pantallazo azul pero no pudo: normalmente el archivo de paginación es muy pequeño o está en otra unidad.'
        fix = 'Activa el archivo de paginación administrado por el sistema en C: y, en Propiedades del sistema → Inicio y recuperación, elige "Volcado de memoria pequeño".'
    }
    'Microsoft-Windows-Kernel-PnP|219'             = @{ kind = 'sistema'; sev = 'aviso'; titulo = 'No se pudo cargar el driver de un dispositivo'
        causa = 'Windows no pudo iniciar el controlador de un dispositivo conectado; ese dispositivo puede quedar sin funcionar.'
        fix = 'Abre el Administrador de dispositivos y busca el dispositivo con signo de admiración; reinstala o actualiza su driver.'
    }
    'Display|4101'                                 = @{ kind = 'grafica'; sev = 'error'; titulo = 'El driver de video dejó de responder y se recuperó (TDR)'
        causa = 'La tarjeta gráfica se colgó y Windows tuvo que reiniciar su driver. Causas típicas: driver defectuoso, sobrecalentamiento de la GPU, overclock o fuente insuficiente.'
        fix = 'Reinstala el driver de la gráfica en limpio (con DDU), limpia el polvo de la tarjeta, quita el overclock y verifica la fuente de poder.'
    }
    'Application Error|1000'                       = @{ kind = 'aplicacion'; sev = 'error'; titulo = 'Un programa se cerró de forma inesperada'
        causa = 'La aplicación falló y Windows la cerró. Suele ser un error del programa, una instalación dañada o un complemento incompatible.'
        fix = 'Actualiza o reinstala el programa. Si falla siempre en el mismo módulo (.dll), busca ese archivo: suele señalar al complemento culpable.'
    }
    'Application Hang|1002'                        = @{ kind = 'aplicacion'; sev = 'error'; titulo = 'Un programa dejó de responder'
        causa = 'La aplicación se congeló y Windows la dio por colgada: puede ser el propio programa, un disco lento o falta de memoria.'
        fix = 'Actualiza el programa. Si el equipo va lento en general, revisa el uso del disco y la memoria RAM disponible.'
    }
    '.NET Runtime|1026'                            = @{ kind = 'aplicacion'; sev = 'error'; titulo = 'Un programa .NET falló con una excepción no controlada'
        causa = 'Una aplicación hecha en .NET lanzó un error que nadie atendió y se cerró.'
        fix = 'Actualiza el programa y el runtime de .NET; si es un programa propio, revisa el detalle de la excepción de abajo.'
    }
    'Service Control Manager|7000'                 = @{ kind = 'servicio'; sev = 'error'; titulo = 'Un servicio no pudo iniciarse'
        causa = 'Windows no pudo arrancar el servicio: ejecutable ausente, permisos, dependencias o configuración incorrecta.'
        fix = 'Abre services.msc, revisa el servicio y su cuenta de inicio; reinstala el programa dueño del servicio.'
    }
    'Service Control Manager|7001'                 = @{ kind = 'servicio'; sev = 'error'; titulo = 'Un servicio no arrancó porque otro del que depende falló'
        causa = 'El servicio depende de otro que no pudo iniciar.'
        fix = 'Localiza el servicio del que depende en services.msc y corrige ese primero.'
    }
    'Service Control Manager|7009'                 = @{ kind = 'servicio'; sev = 'error'; titulo = 'Un servicio tardó demasiado en iniciar'
        causa = 'El servicio superó el tiempo de espera al arrancar; suele pasar en equipos lentos o con el disco saturado.'
        fix = 'Revisa la salud y el uso del disco. Si es un servicio de terceros, reinstálalo o retrasa su inicio.'
    }
    'Service Control Manager|7011'                 = @{ kind = 'servicio'; sev = 'error'; titulo = 'Un servicio no respondió a tiempo'
        causa = 'El servicio dejó de responder al administrador de servicios: disco saturado, programa colgado o falta de recursos.'
        fix = 'Revisa el disco y la memoria; actualiza o reinstala el programa dueño del servicio.'
    }
    'Service Control Manager|7023'                 = @{ kind = 'servicio'; sev = 'error'; titulo = 'Un servicio terminó con error'
        causa = 'El servicio se detuvo devolviendo un código de error.'
        fix = 'Revísalo en services.msc e intenta iniciarlo a mano para ver el mensaje; reinstala el programa si persiste.'
    }
    'Service Control Manager|7031'                 = @{ kind = 'servicio'; sev = 'error'; titulo = 'Un servicio se cerró de forma inesperada'
        causa = 'El servicio se cayó y Windows tuvo que reiniciarlo.'
        fix = 'Actualiza o reinstala el programa dueño del servicio; si es de Windows, corre "sfc /scannow".'
    }
    'Service Control Manager|7034'                 = @{ kind = 'servicio'; sev = 'error'; titulo = 'Un servicio se cerró inesperadamente varias veces'
        causa = 'El servicio se está cayendo repetidamente.'
        fix = 'Reinstala el programa dueño del servicio; si es de Windows, corre "sfc /scannow" y "DISM /Online /Cleanup-Image /RestoreHealth".'
    }
    'Microsoft-Windows-DistributedCOM|10016'       = @{ kind = 'sistema'; sev = 'aviso'; titulo = 'Permisos DCOM (ruido conocido de Windows)'
        causa = 'Un componente pidió permisos DCOM que no tiene. Microsoft lo considera normal: NO afecta al funcionamiento del equipo.'
        fix = 'No requiere acción. Solo tiene sentido tocarlo si un programa concreto falla siempre por esto.'
    }
    'Microsoft-Windows-DistributedCOM|10005'       = @{ kind = 'sistema'; sev = 'aviso'; titulo = 'DCOM no pudo iniciar un servicio'
        causa = 'Un componente COM intentó arrancar un servicio deshabilitado o inexistente.'
        fix = 'Normalmente inofensivo. Si un programa falla por esto, revisa que su servicio esté habilitado en services.msc.'
    }
    'Microsoft-Windows-DriverFrameworks-UserMode|10111' = @{ kind = 'sistema'; sev = 'aviso'; titulo = 'Un driver en modo usuario dejó de responder'
        causa = 'Un dispositivo (normalmente USB) no respondió al apagar o suspender el equipo.'
        fix = 'Actualiza el driver del dispositivo y desconéctalo antes de suspender si el problema persiste.'
    }
    'Microsoft-Windows-Kernel-Boot|29'             = @{ kind = 'sistema'; sev = 'aviso'; titulo = 'Problema al aplicar la configuración de arranque'
        causa = 'Windows no pudo aplicar parte de la configuración de arranque (BCD).'
        fix = 'Si el equipo arranca bien, es inofensivo. Si no, repara el arranque con "bcdboot" desde el medio de instalación.'
    }
}

function Info-Evento($proveedor, $id, $nivel) {
    $clave = "$proveedor|$id"
    if ($EVENTOS.ContainsKey($clave)) { return $EVENTOS[$clave] }
    $sev = 'error'
    if ($nivel -eq 1) { $sev = 'critico' }
    return @{
        kind = 'sistema'; sev = $sev
        titulo = "$proveedor informo un error (evento $id)"
        causa = 'PCInfo no tiene este evento en su catalogo de causas conocidas, asi que hay que leer el mensaje original de abajo para saber que paso.'
        fix = "Busca el texto del error junto con '$proveedor' y el numero de evento $id. Si el componente pertenece a un programa instalado, actualizalo o reinstalalo."
    }
}

# ==============================================================================
#  Lectura de eventos
# ==============================================================================

# En modo OFFLINE no se puede preguntar al servicio de registro de eventos (el
# Windows analizado esta apagado): se leen sus archivos .evtx directamente.
# LogName 'System' -> <Raiz>\System32\winevt\Logs\System.evtx
function Get-Eventos($filtro, $max) {
    if (-not $OFFLINE) {
        try { return @(Get-WinEvent -FilterHashtable $filtro -MaxEvents $max -ErrorAction Stop) }
        catch { return @() }
    }
    $archivo = Join-Path $LOGS ("$($filtro['LogName']).evtx")
    if (-not (Test-Path $archivo)) { return @() }
    # Get-WinEvent tambien sabe leer un .evtx suelto (clave Path del filtro).
    $f = @{ Path = $archivo }
    foreach ($k in $filtro.Keys) { if ($k -ne 'LogName') { $f[$k] = $filtro[$k] } }
    try { return @(Get-WinEvent -FilterHashtable $f -MaxEvents $max -ErrorAction Stop) }
    catch { return (Lee-Evtx $archivo $filtro $max) }
}

# Respaldo para entornos recortados (WinPE / Hiren's) donde Get-WinEvent puede no
# estar disponible: la misma lectura con la API .NET de eventos y una consulta
# XPath equivalente al filtro.
function Xpath-Filtro($filtro) {
    $cond = @()
    if ($filtro['ProviderName']) { $cond += "Provider[@Name='$($filtro['ProviderName'])']" }
    if ($filtro['Id']) { $cond += "(EventID=$($filtro['Id']))" }
    if ($filtro['Level']) { $cond += '(' + ((@($filtro['Level']) | ForEach-Object { "Level=$_" }) -join ' or ') + ')' }
    $cond += "TimeCreated[timediff(@SystemTime) <= $([int64]$Dias * 86400000)]"
    return '*[System[' + ($cond -join ' and ') + ']]'
}

function Lee-Evtx([string]$archivo, $filtro, [int]$max) {
    $res = @()
    $lector = $null
    try {
        $consulta = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery(
            $archivo, [System.Diagnostics.Eventing.Reader.PathType]::FilePath, (Xpath-Filtro $filtro))
        $consulta.ReverseDirection = $true   # del mas reciente al mas viejo
        $lector = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($consulta)
        while ($res.Count -lt $max) {
            $ev = $lector.ReadEvent()
            if ($null -eq $ev) { break }
            $res += $ev
        }
    } catch { return @() }
    finally { if ($lector) { try { $lector.Dispose() } catch { } } }
    return @($res)
}

# El texto de un evento lo arma el proveedor que lo emitio. Analizando un Windows
# apagado esos textos pueden no resolverse (las DLL de mensajes son las del
# sistema vivo): en ese caso se cae al contenido crudo del evento, que basta
# porque el diagnostico sale del catalogo por proveedor+Id, no del mensaje.
function Mensaje($e) {
    try { if ($e.Message) { return "$($e.Message)" } } catch { }
    try { if ($e.FormatDescription()) { return "$($e.FormatDescription())" } } catch { }
    try {
        $xml = [xml]$e.ToXml()
        $partes = @()
        foreach ($d in $xml.Event.EventData.Data) {
            $n = "$($d.Name)"; $v = "$($d.'#text')"
            if ($v) { if ($n) { $partes += "${n}: $v" } else { $partes += $v } }
        }
        if ($partes.Count -gt 0) { return "(Sin texto descriptivo: el sistema analizado no esta en ejecucion)`r`n" + ($partes -join "`r`n") }
    } catch { }
    return '(El evento no trae texto descriptivo)'
}

# Acepta cualquier valor (algunos registros llegan sin fecha) para no reventar
# la recoleccion completa por un evento raro.
function Fecha($t) {
    if ($null -eq $t) { return '' }
    try { return ([datetime]$t).ToString('yyyy-MM-dd HH:mm:ss') } catch { return '' }
}

$items = New-Object System.Collections.ArrayList
# =============================================================================
#  CORRELACION ENTRE VOLCADOS
# -----------------------------------------------------------------------------
#  Un volcado suelto casi nunca nombra al culpable: en un caso real, de 5
#  minidumps solo UNO tenia un driver de terceros en la pila. Lo que si delata
#  al culpable es el PATRON entre volcados: los drivers de Bitdefender salian
#  en la lista de descargados de los CINCO.
#
#  Aqui se cuenta, para cada driver de terceros, en cuantos volcados aparecio y
#  como. "6 de 8 pantallazos" es lo que convierte un sospechoso en un culpable,
#  y es lo que hace falta para poder decir QUE driver desinstalar.
# =============================================================================
$global:TotalAnalizados = 0
$global:Acumulado = @{}

function Anota-Culpable([string]$nombre, [string]$como) {
    if (-not $nombre) { return }
    # El nombre de los descargados viene recortado a 12 caracteres por Windows.
    # Se usa tal cual como clave: recortar los demas los mezclaria.
    $k = $nombre.ToLower()
    if (-not $global:Acumulado.ContainsKey($k)) {
        $global:Acumulado[$k] = [pscustomobject]@{ Nombre = $nombre; Pila = 0; Descarga = 0 }
    }
    if ($como -eq 'pila') { $global:Acumulado[$k].Pila++ } else { $global:Acumulado[$k].Descarga++ }
}

$dumps = Get-Minidumps

# ---- 1) Pantallazos azules ---------------------------------------------------
$bsod = @()
foreach ($e in (Get-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $desde } 60)) {
    $msg = Mensaje $e
    # Analizando un sistema apagado el texto puede no resolverse; el parametro
    # crudo del evento 1001 ("0x0000007e (0x...,...)") lleva el mismo STOP code.
    try {
        $crudo = @($e.Properties | ForEach-Object { "$($_.Value)" }) -join ' '
        if ($crudo -and ($msg -notmatch '0x[0-9A-Fa-f]{8}')) { $msg = "$msg`r`n$crudo" }
    } catch { }
    $stop = ''; $params = ''; $rutaDump = ''
    if ($msg -match '(0x[0-9A-Fa-f]{8,16})\s*\(0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+\)') { $stop = $Matches[1] }
    if ($msg -match '\((0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+)\)') { $params = $Matches[1] }
    if ($msg -match '([A-Za-z]:\\[^\r\n]+\.(?:dmp|DMP))') { $rutaDump = $Matches[1] }
    $bsod += [pscustomobject]@{ Cuando = $e.TimeCreated; Id = "bsod-1001-$($e.RecordId)"; Fuente = "Evento 1001 WER-SystemErrorReporting"; Stop = $stop; Params = $params; Dump = $rutaDump; Mensaje = $msg }
}
foreach ($e in (Get-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $desde } 60)) {
    $stop = ''; $extra = ''
    try {
        $xml = [xml]$e.ToXml(); $data = @{}
        foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
        $code = $data['BugcheckCode']
        if ($code -and $code -ne '0') {
            $stop = '0x' + ([int64]$code).ToString('X8')
            $extra = "BugcheckCode $stop, parametros ($($data['BugcheckParameter1']),$($data['BugcheckParameter2']),$($data['BugcheckParameter3']),$($data['BugcheckParameter4']))"
        }
    } catch { }
    if (-not $stop) { continue }  # 41 sin bugcheck = corte de energia: va al catalogo de eventos
    $bsod += [pscustomobject]@{ Cuando = $e.TimeCreated; Id = "bsod-41-$($e.RecordId)"; Fuente = "Evento 41 Kernel-Power"; Stop = $stop; Params = ''; Dump = ''; Mensaje = "$(Mensaje $e)`r`n$extra" }
}

# Analizar un volcado cuesta segundos (se leen decenas de MB y se buscan modulos),
# asi que solo se analizan los mas recientes; los demas se listan con su STOP code.
$maxAnalisis = 8
$analizados = 0
foreach ($b in ($bsod | Sort-Object Cuando -Descending)) {
    $analisis = $null
    $dump = $null
    if ($analizados -lt $maxAnalisis) {
        $dump = Buscar-Dump $b.Cuando $b.Dump $dumps
        if ($dump) { $analizados++; try { $analisis = Analiza-Dump $dump $b.Stop } catch { } }
    }
    $stop = if ($analisis -and $analisis.Stop) { $analisis.Stop } else { $b.Stop }
    $stopNorm = Normaliza-Stop $stop
    $nombre = Nombre-Stop $stop
    $titulo = 'Pantalla azul (BSOD)'
    if ($nombre) { $titulo = "Pantalla azul: $nombre" } elseif ($stopNorm) { $titulo = "Pantalla azul: $stopNorm" }

    # --- Se acumula la evidencia de TODOS los volcados -------------------
    # Un volcado suelto rara vez nombra al culpable; el patron aparece al
    # cruzarlos. Ver Resume-Culpables al final del script.
    if ($analisis) {
        $global:TotalAnalizados++
        foreach ($nm in @($analisis.Pila)) { Anota-Culpable $nm 'pila' }
        foreach ($nm in @($analisis.Descargados)) { Anota-Culpable $nm 'descarga' }
    }

    # OJO: @($null) NO es un array vacio, es un array de UN elemento nulo
    # (@($null).Count vale 1). Y en PS 5.1 leer una propiedad de $null devuelve
    # $null sin avisar, asi que "@($analisis.Evidencia)" con $analisis nulo
    # producia [null] en el JSON y la GUI pintaba la palabra "null". Pasa en
    # todos los pantallazos cuyo volcado no existe, que son muchos.
    $evidencia = @()
    if ($analisis -and $analisis.Evidencia) { $evidencia = @($analisis.Evidencia | Where-Object { $_ }) }

    $culpable = ''; $culpableInfo = ''; $confianza = ''; $sospechosos = @()
    if ($analisis -and $analisis.Culpable) {
        $c = $analisis.Culpable
        $culpable = $c.Nombre
        $culpableInfo = (@($c.Descripcion, $c.Compania, $(if ($c.Version) { "v$($c.Version)" } else { '' }), $c.Ruta) | Where-Object { $_ }) -join ' · '
        $confianza = $analisis.Confianza
        $sospechosos = @($analisis.Sospechosos | Select-Object -First 10 | ForEach-Object { "$($_.Nombre) [$($_.Compania)] v$($_.Version)" })
    }
    $detalle = New-Object System.Text.StringBuilder
    if ($b.Params) { [void]$detalle.AppendLine("Parametros: $($b.Params)") }
    if ($dump) { [void]$detalle.AppendLine("Volcado: $($dump.FullName) ($([math]::Round($dump.Length/1KB)) KB del $($dump.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))") }
    elseif ($b.Dump) { [void]$detalle.AppendLine("Volcado indicado por Windows: $($b.Dump) (ya no existe en el disco)") }
    if ($analisis) {
        if ($analisis.Formato) { [void]$detalle.AppendLine("Formato del volcado: $($analisis.Formato)") }
        if ($analisis.FaultAddr) { [void]$detalle.AppendLine("Direccion del fallo: $($analisis.FaultAddr)") }
        if ($analisis.Nota) { [void]$detalle.AppendLine($analisis.Nota) }
    }
    [void]$detalle.AppendLine('')
    [void]$detalle.AppendLine($b.Mensaje)

    $fix = Fix-Stop $stop
    if ($culpable) { $fix = "Empieza por el driver '$culpable' ($($analisis.Culpable.Compania)): actualizalo desde la pagina del fabricante o revierte su ultima actualizacion. " + $fix }

    [void]$items.Add([ordered]@{
            id = $b.Id; when = (Fecha $b.Cuando); firstWhen = ''; count = 1
            severity = 'critico'; kind = 'pantallazo'; title = $titulo; source = $b.Fuente
            code = $stopNorm; codeName = $nombre
            culprit = $culpable; culpritInfo = $culpableInfo; confidence = $confianza; suspects = $sospechosos
            evidence = $evidencia
            cause = (Causa-Stop $stop); fix = $fix; detail = $detalle.ToString()
        })
}

# ---- 2) Resto de errores del registro (System + Application) -----------------
# Se agrupan por proveedor + Id: 40 veces el mismo error de disco es UN problema.
$grupos = @{}
$orden = New-Object System.Collections.ArrayList
# OJO: no llamar a esta variable $eventos — PowerShell NO distingue mayusculas y
# pisaria el catalogo $EVENTOS, dejando a Info-Evento sin ContainsKey.
$registros = @()
$registros += Get-Eventos @{ LogName = 'System'; Level = 1, 2; StartTime = $desde } $MaxEventos
$registros += Get-Eventos @{ LogName = 'Application'; Level = 1, 2; StartTime = $desde } $MaxEventos

foreach ($e in $registros) {
    $prov = "$($e.ProviderName)"
    $id = [int]$e.Id
    # Los pantallazos ya se procesaron arriba con su análisis de volcado.
    if ($prov -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $id -eq 1001) { continue }
    if ($prov -eq 'Microsoft-Windows-Kernel-Power' -and $id -eq 41) {
        $tieneBug = $false
        try {
            $xml = [xml]$e.ToXml()
            foreach ($d in $xml.Event.EventData.Data) { if ($d.Name -eq 'BugcheckCode' -and $d.'#text' -and $d.'#text' -ne '0') { $tieneBug = $true } }
        } catch { }
        if ($tieneBug) { continue }
    }
    $clave = "$prov|$id"
    $info = Info-Evento $prov $id ([int]$e.Level)
    $cuando = Fecha $e.TimeCreated
    if ($grupos.ContainsKey($clave)) {
        $g = $grupos[$clave]
        $g.count = [int]$g.count + 1
        if ($cuando -lt $g.firstWhen -or -not $g.firstWhen) { $g.firstWhen = $cuando }
        if ($cuando -gt $g.when) { $g.when = $cuando }
        continue
    }
    $titulo = $info.titulo
    # En fallos de servicio/aplicación, el nombre del programa va en el título.
    if ($info.kind -eq 'aplicacion' -or $info.kind -eq 'servicio') {
        $nombreApp = ''
        try {
            $props = @($e.Properties | ForEach-Object { "$($_.Value)" })
            if ($props.Count -gt 0 -and $props[0]) { $nombreApp = ($props[0] -split '\\')[-1] }
        } catch { }
        if ($nombreApp) { $titulo = "$($info.titulo): $nombreApp" }
    }
    $item = [ordered]@{
        id = "evt-$prov-$id"; when = $cuando; firstWhen = $cuando; count = 1
        severity = $info.sev; kind = $info.kind; title = $titulo
        source = "Registro $($e.LogName) · $prov · evento $id"
        code = "$id"; codeName = ''
        culprit = ''; culpritInfo = ''; confidence = ''; suspects = @()
        cause = $info.causa; fix = $info.fix
        detail = (Mensaje $e)
    }
    $grupos[$clave] = $item
    [void]$orden.Add($clave)
}
foreach ($k in $orden) {
    $g = $grupos[$k]
    if ([int]$g.count -le 1) { $g.firstWhen = '' }
    [void]$items.Add($g)
}

# ---- 2b) ¿Se está capturando bien lo que pase? ---------------------------------
# Un reinicio inesperado sin pantallazo registrado ni volcado casi siempre es un
# BSOD que Windows no alcanzó a guardar. Aquí se revisa si el equipo está
# preparado para guardarlos (volcado activo, archivo de paginación) y si la tarea
# de bluescreen sigue registrada. Solo en el Windows vivo: un sistema analizado
# desde otra unidad no se puede preguntar por su tarea ni su paginación.
if (-not $OFFLINE) {
    $problemas = @()
    try {
        $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
        if ($null -ne $cc.CrashDumpEnabled -and [int]$cc.CrashDumpEnabled -eq 0) { $problemas += 'El volcado de memoria está desactivado (CrashDumpEnabled = 0): ningún pantallazo deja archivo .dmp.' }
    } catch { }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        if (-not $cs.AutomaticManagedPagefile -and $pf.Count -eq 0) { $problemas += 'No hay archivo de paginación: Windows no puede escribir el volcado de un pantallazo.' }
    } catch { }
    try {
        if (-not (Get-ScheduledTask -TaskName 'RecopilarBluescreens' -ErrorAction SilentlyContinue)) { $problemas += 'La tarea RecopilarBluescreens no está registrada: nadie anota los pantallazos en C:\bluescreen.md. Se vuelve a crear con "Pantallazos azules (bluescreen)" del menú Inicio.' }
    } catch { }
    $reinicios = 0
    foreach ($r in $registros) {
        if ("$($r.ProviderName)" -eq 'Microsoft-Windows-Kernel-Power' -and [int]$r.Id -eq 41) { $reinicios++ }
    }
    if ($reinicios -gt 0 -and $dumps.Count -eq 0) { $problemas += "Hubo $reinicios reinicio(s) inesperado(s) y no hay ningún volcado en C:\Windows\Minidump: si fueron pantallazos azules, Windows no alcanzó a guardarlos (suele pasar con fallos al arrancar o al reanudar de la suspensión, como ACPI_BIOS_ERROR)." }
    if ($problemas.Count -gt 0) {
        [void]$items.Add([ordered]@{
                id = 'captura-pantallazos'; when = (Fecha (Get-Date)); firstWhen = ''; count = 1
                severity = 'aviso'; kind = 'sistema'; title = 'Los pantallazos azules podrían no estar quedando registrados'
                source = 'Revisión de PCInfo (volcado, paginación y tarea bluescreen)'
                code = ''; codeName = ''
                culprit = ''; culpritInfo = ''; confidence = ''; suspects = @()
                cause = 'Para diagnosticar un pantallazo hace falta que Windows guarde su volcado y que alguien lo anote. Si falta alguna pieza, un fallo real queda sin rastro.'
                fix = 'Corrige lo indicado abajo. Si el pantallazo ocurre al arrancar, fotografía el código y el primer parámetro que muestra la pantalla: sin volcado, esa foto es la única evidencia.'
                detail = ($problemas -join "`r`n")
            })
    }
}

# ---- 3) Volcados presentes en el disco ---------------------------------------
$listaDumps = New-Object System.Collections.ArrayList
foreach ($d in ($dumps | Select-Object -First 30)) {
    [void]$listaDumps.Add([ordered]@{ path = $d.FullName; when = (Fecha $d.LastWriteTime); sizeBytes = [int64]$d.Length })
}
$memdmp = Join-Path $Raiz 'MEMORY.DMP'
if (Test-Path $memdmp) {
    $mi = Get-Item $memdmp
    if (-not ($listaDumps | Where-Object { $_.path -eq $mi.FullName })) {
        [void]$listaDumps.Add([ordered]@{ path = $mi.FullName; when = (Fecha $mi.LastWriteTime); sizeBytes = [int64]$mi.Length })
    }
}

$elevado = $false
try {
    $elevado = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# --- Ranking de culpables, cruzando todos los volcados -----------------------
$culpables = New-Object System.Collections.ArrayList
foreach ($k in $global:Acumulado.Keys) {
    $a = $global:Acumulado[$k]
    $info = Get-DriverInfo $a.Nombre
    # Sin informacion del archivo no se puede saber si es de Microsoft; se
    # descarta para no acusar a un componente del sistema.
    if (-not $info) { continue }
    if (Es-DeMicrosoft $info) { continue }
    $veces = [Math]::Max($a.Pila, $a.Descarga)
    $como = @()
    if ($a.Pila -gt 0)     { $como += "ejecutandose en $($a.Pila) de $global:TotalAnalizados" }
    if ($a.Descarga -gt 0) { $como += "descargandose en $($a.Descarga) de $global:TotalAnalizados" }
    [void]$culpables.Add([ordered]@{
            driver   = $info.Nombre
            device   = $info.Descripcion
            vendor   = $info.Compania
            version  = $info.Version
            path     = $info.Ruta
            inStack  = $a.Pila
            unloading= $a.Descarga
            total    = $global:TotalAnalizados
            why      = ($como -join ' y ')
        })
}
$culpables = @($culpables | Sort-Object -Property @{Expression = { $_.inStack }; Descending = $true }, @{Expression = { $_.unloading }; Descending = $true } | Select-Object -First 10)

$resultado = [ordered]@{
    ok       = $true
    elevated = $elevado
    items    = @($items)
    dumps    = @($listaDumps)
    culprits = @($culpables)
    dumpsAnalyzed = $global:TotalAnalizados
}
$json = $resultado | ConvertTo-Json -Depth 6
Set-Content -Path $Salida -Value $json -Encoding UTF8
