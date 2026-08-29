<#
.SYNOPSIS
    Recopila TODOS los pantallazos azules (BSOD) del equipo en C:\bluescreen.txt.

.DESCRIPTION
    Lee los pantallazos azules desde varias fuentes de Windows y los va acumulando
    en un solo archivo de texto (por defecto C:\bluescreen.txt), con fecha, hora,
    equipo, sistema operativo y todos los detalles de cada evento.

    Fuentes que consulta:
        - Evento 1001  "Microsoft-Windows-WER-SystemErrorReporting"
                       (el clasico "The bugcheck was: 0x..." con codigo, parametros y ruta del dump).
        - Evento 41    "Microsoft-Windows-Kernel-Power"
                       (apagado/reinicio inesperado, con BugcheckCode y parametros).
        - Evento 6008  "EventLog" (apagado inesperado del sistema).
        - Archivos de volcado: C:\Windows\Minidump\*.dmp y C:\Windows\MEMORY.DMP.

    No borra ni modifica nada del sistema: solo LEE registros y ESCRIBE el .txt.

    Para no duplicar, guarda los EventRecordId ya volcados en un marcador
    (C:\bluescreen.txt.procesados) y en cada corrida solo agrega los nuevos.

.PARAMETER Archivo
    Ruta del archivo de salida. Por defecto C:\bluescreen.txt.

.PARAMETER Rehacer
    Borra el archivo y el marcador y vuelve a generar TODO el historial desde cero.

.PARAMETER Ver
    Solo muestra el contenido actual del archivo y termina.

.PARAMETER InstalarTarea
    Crea una tarea programada que corre este script al iniciar Windows (y cada vez
    que se registra un evento 1001), para ir recopilando los BSOD automaticamente.

.PARAMETER QuitarTarea
    Elimina la tarea programada.

.EXAMPLE
    .\bluescreen.ps1
    Recopila los pantallazos nuevos y los agrega a C:\bluescreen.txt.

.EXAMPLE
    .\bluescreen.ps1 -Rehacer
    Regenera todo el historial desde cero.

.EXAMPLE
    .\bluescreen.ps1 -InstalarTarea
    Deja el equipo recopilando BSOD solo, sin que tengas que correrlo a mano.

.NOTES
    Requiere PowerShell 5.1+ y Administrador (el .bat se auto-eleva).
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Archivo = 'C:\bluescreen.txt',
    [switch]$Rehacer,
    [switch]$Ver,
    [switch]$InstalarTarea,
    [switch]$QuitarTarea
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Log([string]$msg, [string]$color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
}

# --- Tabla de codigos de STOP mas comunes -------------------------------------
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
    '0x000000A0' = 'INTERNAL_POWER_ERROR'
    '0x000000C2' = 'BAD_POOL_CALLER'
    '0x000000C4' = 'DRIVER_VERIFIER_DETECTED_VIOLATION'
    '0x000000C5' = 'DRIVER_CORRUPTED_EXPOOL'
    '0x000000CE' = 'DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS'
    '0x000000D1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
    '0x000000EF' = 'CRITICAL_PROCESS_DIED'
    '0x000000F4' = 'CRITICAL_OBJECT_TERMINATION'
    '0x00000109' = 'CRITICAL_STRUCTURE_CORRUPTION'
    '0x00000116' = 'VIDEO_TDR_ERROR'
    '0x00000117' = 'VIDEO_TDR_TIMEOUT_DETECTED'
    '0x00000119' = 'VIDEO_SCHEDULER_INTERNAL_ERROR'
    '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR'
    '0x00000133' = 'DPC_WATCHDOG_VIOLATION'
    '0x0000013A' = 'KERNEL_MODE_HEAP_CORRUPTION'
    '0x00000139' = 'KERNEL_SECURITY_CHECK_FAILURE'
    '0x0000014C' = 'FATAL_UNHANDLED_HARD_ERROR'
    '0x00000154' = 'UNEXPECTED_STORE_EXCEPTION'
    '0x000000BE' = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY'
    '0x000000FC' = 'ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY'
}

function Nombre-Stop([string]$hex) {
    if ([string]::IsNullOrWhiteSpace($hex)) { return '' }
    $k = $hex.Trim().ToLower()
    if ($k -notlike '0x*') { $k = '0x' + $k }
    # normaliza a 10 caracteres (0x + 8 hex) para el lookup
    $num = $k.Substring(2).TrimStart('0')
    if ($num -eq '') { $num = '0' }
    $full = '0x' + $num.PadLeft(8,'0').ToUpper()
    if ($STOPCODES.ContainsKey($full)) { return $STOPCODES[$full] }
    return '(codigo no catalogado)'
}

# --- Guia en espanol: causa tipica + como resolver, por stop code -------------
$STOPGUIA = @{
    '0x0000000A' = 'Un driver accedio a memoria con IRQL demasiado alto. Casi siempre es un DRIVER defectuoso o RAM danada. Actualiza/revierte el driver senalado y corre Diagnostico de memoria de Windows.'
    '0x0000001A' = 'Error de administracion de memoria. Sospecha de RAM danada o driver que corrompe memoria. Corre mdsched.exe (test de RAM) y actualiza drivers de chipset/almacenamiento.'
    '0x0000001E' = 'Excepcion de modo kernel no controlada, normalmente por un DRIVER. El 2do parametro es la direccion que fallo. Actualiza el driver de terceros senalado abajo.'
    '0x00000024' = 'Problema del sistema de archivos NTFS: disco con sectores danados o driver de disco. Corre chkdsk C: /f /r y revisa la salud del disco (SMART).'
    '0x00000050' = 'Se referencio memoria invalida (PAGE_FAULT). Suele ser RAM danada o un DRIVER/antivirus. Test de RAM (mdsched.exe) y actualiza/desinstala el driver senalado.'
    '0x0000007A' = 'No se pudo leer una pagina de memoria del disco: disco/cable/SSD con fallas o controlador de almacenamiento. Revisa SMART del disco y el cable SATA/NVMe.'
    '0x0000007B' = 'Windows no encuentra el disco de arranque: cambio de modo SATA (AHCI/RAID) en BIOS o driver de almacenamiento. Revisa BIOS y el controlador iaStor/stornvme.'
    '0x0000007E' = 'Un hilo del sistema genero una excepcion no controlada, por un DRIVER. Actualiza/revierte el driver de terceros senalado abajo.'
    '0x0000009F' = 'Driver en estado de energia inconsistente (suele pasar al suspender/reanudar). Sospecha de driver de red, chipset o USB. Actualiza esos drivers o desactiva la suspension selectiva.'
    '0x000000C2' = 'Un driver hizo una operacion de pool invalida (BAD_POOL_CALLER). Es un DRIVER defectuoso; identifica el de terceros senalado y actualizalo.'
    '0x000000D1' = 'Un DRIVER accedio a memoria con IRQL alto. Muy comun en drivers de RED/WiFi o GPU. Actualiza o revierte el driver de terceros senalado abajo.'
    '0x000000EF' = 'Un proceso critico del sistema murio. Puede ser corrupcion del sistema o driver/malware. Corre sfc /scannow y DISM /Online /Cleanup-Image /RestoreHealth.'
    '0x000000F4' = 'Un objeto/proceso critico termino: casi siempre DISCO fallando (SSD/HDD) o controlador de almacenamiento. Revisa SMART y actualiza el driver de almacenamiento.'
    '0x00000116' = 'El driver de VIDEO no respondio (TDR). Actualiza o reinstala en limpio el driver de la GPU (nvlddmkm/atikmdag/igdkmd). Si persiste, revisa temperatura de la tarjeta.'
    '0x00000117' = 'El driver de VIDEO se colgo (TDR timeout). Reinstala el driver de la GPU y revisa sobrecalentamiento.'
    '0x00000119' = 'Error interno del programador de video: driver de GPU defectuoso. Reinstala el driver de la tarjeta grafica.'
    '0x00000124' = 'WHEA: error de HARDWARE (CPU, RAM, sobrecalentamiento o fuente). NO es un driver. Revisa temperaturas, limpia el equipo, prueba la RAM y verifica el voltaje/fuente.'
    '0x00000133' = 'Un driver o dispositivo mantuvo la CPU ocupada demasiado tiempo (DPC watchdog). Comun en controladores de ALMACENAMIENTO/SSD viejos. Actualiza el firmware del SSD y el driver de almacenamiento/chipset.'
    '0x00000139' = 'Windows detecto corrupcion en una estructura de seguridad del kernel: DRIVER defectuoso o malware. Actualiza el driver senalado; corre sfc /scannow.'
    '0x0000013A' = 'Corrupcion del heap del kernel, causada por un DRIVER. Identifica y actualiza el driver de terceros senalado.'
    '0x00000154' = 'Excepcion inesperada de almacenamiento: SSD/HDD fallando. Revisa SMART y actualiza firmware del disco.'
}
function Guia-Bugcheck([string]$hex) {
    if ([string]::IsNullOrWhiteSpace($hex)) { return 'Sin codigo de bugcheck. Revisa el .dmp indicado y los drivers de terceros listados.' }
    $k = $hex.Trim().ToLower(); if ($k -notlike '0x*') { $k = '0x' + $k }
    $num = $k.Substring(2).TrimStart('0'); if ($num -eq '') { $num = '0' }
    $full = '0x' + $num.PadLeft(8,'0').ToUpper()
    if ($STOPGUIA.ContainsKey($full)) { return $STOPGUIA[$full] }
    return 'Codigo no catalogado. Como regla: si abajo aparece un driver de TERCEROS, actualizalo o revierte lo ultimo instalado; si no, sospecha de HARDWARE (RAM/disco/temperatura).'
}

# Clase de hardware sospechosa segun el bugcheck (para priorizar el culpable)
function Clase-Bugcheck([string]$hex) {
    if ([string]::IsNullOrWhiteSpace($hex)) { return '' }
    $k = $hex.Trim(); if ($k -notlike '0x*') { $k = '0x' + $k }
    try { $n = [Convert]::ToInt64($k, 16) } catch { return '' }
    switch ($n) {
        0x116 { 'video' } 0x117 { 'video' } 0x119 { 'video' } 0xEA { 'video' }
        0x7A { 'disco' } 0x7B { 'disco' } 0xF4 { 'disco' } 0x154 { 'disco' } 0x133 { 'disco' }
        0xD1 { 'red' } 0x9F { 'red' }
        default { '' }
    }
}
# Subcadenas de nombres de driver por clase (para elegir el mas probable)
$CLASE_HINTS = @{
    video = @('nvlddmkm','nvlddmkm','atikm','amdkm','amdgpu','igdkmd','igfx','nvhda','radeon','intelppm')
    disco = @('iastor','stornvme','storahci','storport','nvme','amdsata','amdxata','rst','disk','samsung','wd_','crucial')
    red   = @('netwtw','netwbw','netwlv','athw','rtwlan','rtl','e1','bcm','mrvl','vwifi','netr','rtux','athr','killer')
}

# --- Informacion de un archivo de driver en disco (nativo, VersionInfo) -------
function Get-DriverInfo([string]$nombre) {
    $dirs = @("$env:SystemRoot\System32\drivers", "$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64", "$env:SystemRoot")
    foreach ($d in $dirs) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $p = Join-Path $d $nombre
        if (Test-Path $p) {
            try {
                $vi = (Get-Item $p).VersionInfo
                return [pscustomobject]@{
                    Nombre      = $nombre
                    Ruta        = $p
                    Compania    = ($vi.CompanyName  | ForEach-Object { $_ }) -replace '\s+$',''
                    Producto    = $vi.ProductName
                    Version     = $vi.FileVersion
                    Descripcion = $vi.FileDescription
                }
            } catch { }
        }
    }
    return $null
}

# =============================================================================
#  LECTURA REAL DEL VOLCADO  (portado de PCInfo Rev 38, 25-ago-2026)
# -----------------------------------------------------------------------------
#  ANTES, el culpable se elegia buscando en el .dmp CUALQUIER cadena que
#  pareciera un nombre de driver, descartando los de Microsoft y quedandose con
#  el primero. Eso NO distingue entre "este driver se estaba ejecutando" y "este
#  nombre aparece suelto en el archivo": en el caso jimena acuso a adp80xx.sys
#  (una controladora SAS que ni siquiera estaba cargada) mientras el culpable
#  real, atc.sys de Bitdefender, aparecia SEIS veces en la pila de llamadas.
#
#  Ahora se leen las estructuras que el propio volcado trae. Es el MISMO codigo
#  que usa la pestana "Historial de Errores" de PCInfo, para que el .txt y la
#  aplicacion no puedan senalar a dos culpables distintos.
#
#  ==> ESTE BLOQUE VIVE EN DOS ARCHIVOS. Si tocas uno, copia al otro:
#         pcinfo/herramientas/bluescreen/bluescreen.ps1    (esta herramienta)
#         www/pcinfo/backend/collector/errores_windows.ps1  (PCInfo)
#      Y OJO: este archivo es ASCII PURO (PS 5.1 lo lee como ANSI sin BOM y
#      rompe los acentos), el de PCInfo va en UTF-8 con BOM y si los lleva.
# =============================================================================

# Lee como maximo $max bytes del archivo (MEMORY.DMP puede pesar varios GB).
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

# Elige el .dmp que corresponde a un evento (por ruta explicita o por cercania de tiempo)
function Buscar-Dump($ev, $dumps) {
    if ($ev.Dump -and (Test-Path $ev.Dump)) { return Get-Item $ev.Dump }
    if (-not $dumps -or $dumps.Count -eq 0) { return $null }
    $best = $null; $bestDiff = [double]::MaxValue
    foreach ($d in $dumps) {
        $diff = [math]::Abs(($d.LastWriteTime - $ev.Cuando).TotalMinutes)
        if ($diff -lt $bestDiff) { $bestDiff = $diff; $best = $d }
    }
    if ($best -and $bestDiff -le 20) { return $best }
    return $null
}

# --- Info del equipo / SO (una sola vez) --------------------------------------
function Get-InfoEquipo {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $bios= try { Get-CimInstance Win32_BIOS } catch { $null }
    $tz  = try { (Get-TimeZone).Id } catch { '' }
    [pscustomobject]@{
        Equipo      = $env:COMPUTERNAME
        Usuario     = $env:USERNAME
        SO          = "$($os.Caption) $($os.Version) (build $($os.BuildNumber)) $($os.OSArchitecture)"
        Fabricante  = "$($cs.Manufacturer) / $($cs.Model)"
        Serie       = if ($bios) { $bios.SerialNumber } else { '' }
        RAM_GB      = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        ZonaHoraria = $tz
    }
}

# --- Recolectores por fuente --------------------------------------------------
# Devuelve objetos { Cuando, RecordId, Fuente, Stop, Params, Dump, Mensaje }

function Get-Eventos1001 {
    $out = @()
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; Id=1001 } -ErrorAction Stop
    } catch { return $out }
    foreach ($e in $ev) {
        $msg = $e.Message
        $stop = ''
        $params = ''
        $dump = ''
        if ($msg -match '(0x[0-9A-Fa-f]{8,16})\s*\(0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+\)') {
            $stop = $Matches[1]
        }
        if ($msg -match '\((0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+,\s*0x[0-9A-Fa-f]+)\)') {
            $params = $Matches[1]
        }
        if ($msg -match '([A-Za-z]:\\[^\r\n]+\.(?:dmp|DMP))') {
            $dump = $Matches[1]
        }
        $out += [pscustomobject]@{
            Cuando   = $e.TimeCreated
            RecordId = "1001-$($e.RecordId)"
            Fuente   = "Evento 1001 WER-SystemErrorReporting (RecordId $($e.RecordId))"
            Stop     = $stop
            Params   = $params
            Dump     = $dump
            Mensaje  = $msg
        }
    }
    return $out
}

function Get-Eventos41 {
    $out = @()
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41 } -ErrorAction Stop
    } catch { return $out }
    foreach ($e in $ev) {
        $bc = ''
        try {
            $xml = [xml]$e.ToXml()
            $data = @{}
            foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
            $code = $data['BugcheckCode']
            if ($code -and $code -ne '0') {
                $hex = '0x' + ([int64]$code).ToString('X8')
                $bc = "BugcheckCode $hex, params ($($data['BugcheckParameter1']),$($data['BugcheckParameter2']),$($data['BugcheckParameter3']),$($data['BugcheckParameter4']))"
                $stop = $hex
            } else {
                # 41 sin bugcheck = corte de energia / cuelgue sin BSOD; lo omitimos para no ensuciar
                continue
            }
        } catch { continue }
        $out += [pscustomobject]@{
            Cuando   = $e.TimeCreated
            RecordId = "41-$($e.RecordId)"
            Fuente   = "Evento 41 Kernel-Power (RecordId $($e.RecordId))"
            Stop     = $stop
            Params   = ''
            Dump     = ''
            Mensaje  = "$($e.Message)`r`n$bc"
        }
    }
    return $out
}

function Get-Eventos6008 {
    $out = @()
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='EventLog'; Id=6008 } -ErrorAction Stop
    } catch { return $out }
    foreach ($e in $ev) {
        $out += [pscustomobject]@{
            Cuando   = $e.TimeCreated
            RecordId = "6008-$($e.RecordId)"
            Fuente   = "Evento 6008 EventLog (RecordId $($e.RecordId))"
            Stop     = ''
            Params   = ''
            Dump     = ''
            Mensaje  = $e.Message
        }
    }
    return $out
}

function Get-Minidumps {
    $dumps = @()
    $rutas = @('C:\Windows\Minidump', 'C:\Windows')
    foreach ($r in $rutas) {
        if (Test-Path $r) {
            try {
                $dumps += Get-ChildItem -Path $r -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
                          Where-Object { $_.FullName -notmatch '\\Temp\\' }
            } catch {}
        }
    }
    return $dumps | Sort-Object LastWriteTime -Descending
}

# --- Escritura de una entrada -------------------------------------------------
function Format-Entrada($ev, $indice, $info, $dumps) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('================================================================================')
    [void]$sb.AppendLine("  BLUESCREEN  #$indice")
    [void]$sb.AppendLine('================================================================================')
    [void]$sb.AppendLine(("Fecha / Hora : {0:yyyy-MM-dd HH:mm:ss}  ({1})" -f $ev.Cuando, $info.ZonaHoraria))
    [void]$sb.AppendLine("Equipo       : $($info.Equipo)")
    [void]$sb.AppendLine("Usuario      : $($info.Usuario)")
    [void]$sb.AppendLine("Sistema      : $($info.SO)")
    [void]$sb.AppendLine("Hardware     : $($info.Fabricante)  |  RAM $($info.RAM_GB) GB  |  Serie $($info.Serie)")
    [void]$sb.AppendLine("Origen       : $($ev.Fuente)")
    if ($ev.Stop) {
        [void]$sb.AppendLine("Stop code    : $($ev.Stop)  $(Nombre-Stop $ev.Stop)")
    }
    if ($ev.Params) {
        [void]$sb.AppendLine("Parametros   : $($ev.Params)")
    }

    # Localiza y analiza el volcado (.dmp) de este pantallazo
    $dump = Buscar-Dump $ev $dumps
    $analisis = $null
    if ($dump) {
        [void]$sb.AppendLine("Archivo dump : $($dump.FullName)  ($([math]::Round($dump.Length/1KB)) KB, $($dump.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))")
        try { $analisis = Analiza-Dump $dump $ev.Stop } catch { }
    } elseif ($ev.Dump) {
        $existe = if (Test-Path $ev.Dump) { 'existe' } else { 'YA NO existe (se sobrescribio)' }
        [void]$sb.AppendLine("Archivo dump : $($ev.Dump)  ($existe)")
    }

    # ---------------- Bloque del causante (facil de ubicar) -------------------
    $stopParaGuia = if ($analisis -and $analisis.Stop) { $analisis.Stop } else { $ev.Stop }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('/****CAUSANTE DEL ERROR****/')
    if ($analisis -and $analisis.Culpable) {
        $c = $analisis.Culpable
        [void]$sb.AppendLine("  Probable causante : $($c.Nombre)")
        [void]$sb.AppendLine("  Descripcion       : $($c.Descripcion)")
        [void]$sb.AppendLine("  Fabricante        : $($c.Compania)")
        [void]$sb.AppendLine("  Version           : $($c.Version)")
        [void]$sb.AppendLine("  Ubicacion         : $($c.Ruta)")
        [void]$sb.AppendLine("  Confianza         : $($analisis.Confianza)")
    } elseif ($analisis -and $analisis.Nota) {
        [void]$sb.AppendLine("  Probable causante : $($analisis.Nota)")
    } else {
        [void]$sb.AppendLine("  Probable causante : no se pudo analizar un .dmp (revisa el stop code y la guia de abajo).")
    }
    # POR QUE se le acusa. Sin esto, "confianza alta" y "confianza baja" son
    # etiquetas opacas: la diferencia entre "estaba en la pila de llamadas" y
    # "su nombre aparece suelto en el archivo" es la que decide si vale la pena
    # desinstalar un driver.
    if ($analisis -and $analisis.Evidencia) {
        foreach ($e in @($analisis.Evidencia | Where-Object { $_ })) {
            [void]$sb.AppendLine("  Por que            : $e")
        }
    }
    # La nota se imprime tambien cuando SI hubo culpable (trae el detalle del
    # volcado); arriba solo sale cuando no hay a quien senalar.
    if ($analisis -and $analisis.Culpable -and $analisis.Nota) {
        [void]$sb.AppendLine("  Nota              : $($analisis.Nota)")
    }
    if ($analisis -and $analisis.FaultAddr) {
        [void]$sb.AppendLine("  Direccion de fallo: $($analisis.FaultAddr)")
    }
    if ($analisis -and $analisis.Formato) {
        [void]$sb.AppendLine("  Volcado           : $($analisis.Formato)")
    }
    if ($analisis -and $analisis.Pila -and $analisis.Pila.Count -gt 0) {
        [void]$sb.AppendLine("  Pila de llamadas  : $((@($analisis.Pila) | Select-Object -First 8) -join ' -> ')")
    }
    if ($analisis -and $analisis.Descargados -and $analisis.Descargados.Count -gt 0) {
        [void]$sb.AppendLine("  Se descargaban    : $((@($analisis.Descargados) | Select-Object -First 8) -join ', ')")
    }
    [void]$sb.AppendLine("  Como solucionarlo : $(Guia-Bugcheck $stopParaGuia)")
    # OJO: cuando HAY culpable, el primer sospechoso ES el culpable (asi lo
    # arma Analiza-Dump) y repetirlo aqui seria confuso. Cuando no lo hay, la
    # lista son todos sospechosos y no se salta ninguno.
    if ($analisis -and $analisis.Sospechosos) {
        $otros = @($analisis.Sospechosos)
        if ($analisis.Culpable -and $otros.Count -gt 0) { $otros = @($otros | Select-Object -Skip 1) }
        if ($otros.Count -gt 0) {
            [void]$sb.AppendLine('  Otros drivers de terceros (sospechosos secundarios, SIN prueba):')
            foreach ($s in ($otros | Select-Object -First 10)) {
                [void]$sb.AppendLine("      - $($s.Nombre)  [$($s.Compania)]  v$($s.Version)")
            }
        }
    }
    [void]$sb.AppendLine('/****FIN CAUSANTE****/')
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('--- Detalle crudo del evento ---------------------------------------------------')
    foreach ($linea in ($ev.Mensaje -split "`r?`n")) {
        [void]$sb.AppendLine($linea)
    }
    [void]$sb.AppendLine('')
    return $sb.ToString()
}

# --- Tarea programada ---------------------------------------------------------
$TASK_NAME = 'RecopilarBluescreens'

# ---------------------------------------------------------------------------
#  ESTAS CLAVES LAS TOCA TAMBIEN optimizador_tuxor. RESUELTO el 25-ago-2026:
#  las dos herramientas quedan alineadas en CrashDumpEnabled = 3.
#
#      clave                  bluescreen        optimizador_tuxor
#      CrashDumpEnabled       3 (pequeno)       3 (pequeno)        <- alineado
#      AlwaysKeepMemoryDump   ya no se toca     no la toca         <- alineado
#      AutoReboot             1 (reinicia)      0 (se queda)       <- SIGUE distinto
#
#  Por que el 3 y no el 7: no es por espacio, es porque el 3 ES EL QUE SI SE
#  ESCRIBE. El 7 necesita muchisima mas paginacion y falla cuando no la hay
#  (caso jimena: 32 pantallazos, 13 eventos 161 de volmgr y solo 5 volcados).
#  Y basta para diagnosticar: el minidump de 3 MB trae la lista de modulos con
#  su base, la de drivers DESCARGADOS y la pila de llamadas, que es todo lo que
#  usa Analiza-Dump. Asi salio atc.sys sin abrir el MEMORY.DMP de 1,9 GB.
#  AlwaysKeepMemoryDump no se toca: solo aplica al volcado completo, que con el
#  modo 3 ya no se genera.
#  Si se vuelven a separar, cambiar en LOS DOS archivos.
# ---------------------------------------------------------------------------
# Asegura que Windows GUARDE un minidump en cada BSOD (asi hay .dmp que analizar)
function Asegura-Minidumps {
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    try {
        Set-ItemProperty -Path $k -Name 'CrashDumpEnabled'    -Value 3 -Type DWord -Force
        Set-ItemProperty -Path $k -Name 'MinidumpDir'         -Value '%SystemRoot%\Minidump' -Type ExpandString -Force
        Set-ItemProperty -Path $k -Name 'AutoReboot'          -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $k -Name 'MinidumpsCount'      -Value 50 -Type DWord -Force
        Log 'Minidumps habilitados (Windows guardara un .dmp en cada pantallazo).' 'Green'
    } catch {
        Log "No se pudo configurar el registro de volcados: $($_.Exception.Message)" 'Yellow'
    }
    Asegura-Paginacion
}

# ---------------------------------------------------------------------------
#  SIN ESTO, LO DE ARRIBA NO SIRVE DE NADA.
#
#  Windows escribe el volcado del pantallazo EN EL ARCHIVO DE PAGINACION de la
#  unidad de arranque, y no lo copia a \Minidump hasta el siguiente arranque.
#  Si el archivo de paginacion no existe, esta en otra unidad, o se quedo corto
#  para el modo de volcado elegido, EL VOLCADO NO SE CREA: lo unico que queda es
#  el evento 161 de volmgr ("Error al crear el archivo de volcado").
#
#  Caso real (jimena, 25-ago-2026): 32 pantallazos, 13 eventos 161 y solo 5
#  volcados en el disco. 13 diagnosticos que ya no se pudieron hacer, con esta
#  herramienta instalada y "funcionando". Entonces ponia CrashDumpEnabled = 7,
#  el modo que MAS paginacion necesita; hoy pone 3, que necesita muchisima
#  menos. Aun asi el archivo de paginacion se sigue garantizando: sin el, ni
#  siquiera el minidump de 3 MB llega a escribirse.
# ---------------------------------------------------------------------------
function Asegura-Paginacion {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.AutomaticManagedPagefile) {
            Log 'Archivo de paginacion: administrado por el sistema (correcto).' 'Green'
        } else {
            # Administrado por el sistema es el unico modo en el que Windows
            # garantiza que el archivo tenga el tamano que el volcado necesita.
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
            Log 'Archivo de paginacion puesto en administrado por el sistema.' 'Green'
            Log 'REINICIA el equipo para que el cambio surta efecto.' 'Yellow'
        }
        # Si el archivo se borra al apagar, el volcado del pantallazo anterior se
        # pierde antes de que Windows alcance a copiarlo a \Minidump.
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' `
                         -Name 'ClearPageFileAtShutdown' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    } catch {
        Log "No se pudo garantizar el archivo de paginacion: $($_.Exception.Message)" 'Yellow'
        Log 'Sin el, los pantallazos pueden NO dejar volcado (evento 161 de volmgr).' 'Yellow'
        Log 'Ponlo a mano: Propiedades del sistema > Opciones avanzadas > Rendimiento' 'Yellow'
        Log '> Opciones avanzadas > Memoria virtual > Administrado por el sistema.' 'Yellow'
    }
}

function Instalar-Tarea {
    $ps1 = $PSCommandPath
    $accion = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`" -Archivo `"$Archivo`""
    Asegura-Minidumps
    Log "Creando tarea '$TASK_NAME' (actua como servicio: se dispara sola al ocurrir un BSOD)..." 'Cyan'

    # Disparador por EVENTO: cada vez que Windows registra el 1001 del BSOD (al reiniciar).
    $xmlTrigger = @"
<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-WER-SystemErrorReporting'] and (EventID=1001)]]</Select></Query></QueryList>
"@
    try {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $accion
        # Disparador 1: al ocurrir el evento del pantallazo (lo esencial).
        $trgEvt = New-CimInstance -CimClass (Get-CimClass MSFT_TaskEventTrigger root/Microsoft/Windows/TaskScheduler) -ClientOnly
        $trgEvt.Enabled = $true
        $trgEvt.Subscription = $xmlTrigger
        # Disparador 2 (respaldo): al arrancar, por si el evento se registro antes de existir la tarea.
        $trgBoot = New-ScheduledTaskTrigger -AtStartup
        $trgBoot.Delay = 'PT2M'
        $ppl = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName $TASK_NAME -Action $act -Trigger @($trgEvt,$trgBoot) -Principal $ppl -Settings $set -Force | Out-Null
        Log "Listo. La tarea correra sola cada vez que ocurra un pantallazo azul." 'Green'
    } catch {
        Log "No se pudo registrar el disparador por evento: $($_.Exception.Message)" 'Yellow'
        Log "Instalando respaldo por arranque (schtasks ONSTART)..." 'Yellow'
        schtasks /Create /F /TN $TASK_NAME /SC ONSTART /DELAY 0002:00 /RU SYSTEM /RL HIGHEST `
            /TR "powershell.exe $accion" | Out-Null
        Log "Tarea creada solo con disparador de arranque." 'Yellow'
    }
}

function Quitar-Tarea {
    Log "Eliminando tarea '$TASK_NAME'..." 'Cyan'
    schtasks /Delete /F /TN $TASK_NAME 2>$null | Out-Null
    Log 'Tarea eliminada (si existia).' 'Green'
}

# ==============================================================================
#  FLUJO PRINCIPAL
# ==============================================================================

if ($QuitarTarea) { Quitar-Tarea; return }
if ($InstalarTarea) { Instalar-Tarea }   # instala y CONTINUA para capturar lo ya ocurrido

if ($Ver) {
    if (Test-Path $Archivo) { Get-Content -Path $Archivo -Encoding UTF8 }
    else { Log "Todavia no existe $Archivo (aun no se ha recopilado nada)." 'Yellow' }
    return
}

$marcador = "$Archivo.procesados"

if ($Rehacer) {
    Remove-Item $Archivo -ErrorAction SilentlyContinue
    Remove-Item $marcador -ErrorAction SilentlyContinue
    Log 'Modo -Rehacer: se regenera todo el historial desde cero.' 'Yellow'
}

$info = Get-InfoEquipo

# Ids ya procesados
$procesados = @{}
if (Test-Path $marcador) {
    foreach ($id in (Get-Content $marcador -ErrorAction SilentlyContinue)) {
        if ($id.Trim()) { $procesados[$id.Trim()] = $true }
    }
}

Log 'Leyendo registros de eventos (WER 1001, Kernel-Power 41, EventLog 6008)...' 'Cyan'
$eventos = @()
$eventos += Get-Eventos1001
$eventos += Get-Eventos41
$eventos += Get-Eventos6008

# ordena cronologicamente ascendente para numerar en orden
$eventos = $eventos | Where-Object { $_ } | Sort-Object Cuando

# Filtra los nuevos
$nuevos = $eventos | Where-Object { -not $procesados.ContainsKey($_.RecordId) }

# Volcados presentes en disco (se usan para hallar el causante de cada evento)
$dumps = Get-Minidumps

# Cabecera del archivo si es la primera vez
$primeraVez = -not (Test-Path $Archivo)
if ($primeraVez) {
    $cab = @()
    $cab += 'REGISTRO DE PANTALLAZOS AZULES (BSOD)'
    $cab += "Equipo   : $($info.Equipo)"
    $cab += "Sistema  : $($info.SO)"
    $cab += "Hardware : $($info.Fabricante)  |  RAM $($info.RAM_GB) GB"
    $cab += "Creado   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $cab += 'Este archivo se va llenando solo cada vez que corre bluescreen.bat / la tarea programada.'
    $cab += ''
    Set-Content -Path $Archivo -Value ($cab -join "`r`n") -Encoding UTF8
}

# indice de arranque = cuantas entradas hay ya
$indiceBase = 0
if (-not $primeraVez) {
    try {
        $ya = Select-String -Path $Archivo -Pattern 'BLUESCREEN  #' -ErrorAction SilentlyContinue
        $indiceBase = ($ya | Measure-Object).Count
    } catch { $indiceBase = 0 }
}

if (($nuevos | Measure-Object).Count -eq 0) {
    Log 'No hay pantallazos azules nuevos que agregar.' 'Green'
} else {
    $i = $indiceBase
    $nuevasLineas = New-Object System.Text.StringBuilder
    foreach ($ev in $nuevos) {
        $i++
        [void]$nuevasLineas.Append((Format-Entrada $ev $i $info $dumps))
        Add-Content -Path $marcador -Value $ev.RecordId -Encoding UTF8
    }
    Add-Content -Path $Archivo -Value $nuevasLineas.ToString() -Encoding UTF8
    Log "Se agregaron $(( $nuevos | Measure-Object).Count) pantallazo(s) nuevo(s) a $Archivo." 'Green'
}

# Anexo: inventario de archivos de volcado presentes (se reescribe cada corrida)
if ($dumps -and $dumps.Count -gt 0) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- Archivos de volcado (.dmp) presentes ahora en el disco --------------------')
    [void]$sb.AppendLine("Actualizado: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    foreach ($d in $dumps) {
        [void]$sb.AppendLine(("  {0:yyyy-MM-dd HH:mm}  {1,10:N0} bytes  {2}" -f $d.LastWriteTime, $d.Length, $d.FullName))
    }
    $anexo = "$Archivo.dumps.txt"
    Set-Content -Path $anexo -Value $sb.ToString() -Encoding UTF8
}

Log ''
Log "Listo. Archivo: $Archivo" 'Cyan'
$total = 0
try { $total = ((Select-String -Path $Archivo -Pattern 'BLUESCREEN  #' -ErrorAction SilentlyContinue) | Measure-Object).Count } catch {}
Log "Total de pantallazos registrados hasta ahora: $total" 'Cyan'
