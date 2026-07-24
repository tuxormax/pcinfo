<#
    errores_windows.ps1 — recolector del "Historial de Errores" de PCInfo (Windows).

    Lo ejecuta el backend Go (collector/errors_windows.go) y ESCRIBE UN JSON en la
    ruta -Salida; no imprime nada ni toca el sistema (solo LEE registros y .dmp).

    Fuentes:
      - Evento 1001 Microsoft-Windows-WER-SystemErrorReporting  → pantallazo azul (BSOD)
      - Evento 41   Microsoft-Windows-Kernel-Power (con BugcheckCode) → BSOD sin WER
      - Evento 6008 EventLog → apagado inesperado
      - C:\Windows\Minidump\*.dmp y C:\Windows\MEMORY.DMP → análisis del culpable
      - Registro System y Application, niveles Crítico(1) y Error(2) → resto de fallos

    Portado de www/windows/bluescreen.ps1 (catálogo de STOP codes, guía en español y
    deducción del driver culpable a partir del volcado, sin herramientas externas).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Salida,
    [int]$Dias = 30,
    [int]$MaxEventos = 400
)

$ErrorActionPreference = 'Stop'
$desde = (Get-Date).AddDays(-$Dias)

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

function Analiza-Dump($archivoDump, $stopEvento) {
    $res = [pscustomobject]@{
        Archivo = $archivoDump.FullName; Formato = ''; Stop = $stopEvento; FaultAddr = ''
        Culpable = $null; Confianza = 'baja'; Sospechosos = @(); Nota = ''
    }
    # 16 MB basta: un minidump completo pesa mucho menos y de MEMORY.DMP (que
    # puede ocupar GB) la lista de modulos vive al principio. Leer mas haria que
    # la busqueda de modulos tardara minutos.
    try { $bytes = Lee-Bytes $archivoDump.FullName (16MB) }
    catch { $res.Nota = "No se pudo leer el volcado: $($_.Exception.Message)"; return $res }
    if ($bytes.Length -lt 0x1000) { $res.Nota = 'El volcado esta incompleto o es demasiado pequeno.'; return $res }

    $sig = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8)
    if ($sig -like 'PAGEDU64*') {
        $res.Formato = 'Kernel x64 (PAGEDU64)'
        try {
            $bc = [BitConverter]::ToUInt32($bytes, 0x38)
            if ($bc -ne 0 -and -not $res.Stop) { $res.Stop = '0x' + $bc.ToString('X8') }
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

    # Nombres de módulos presentes en el volcado (ASCII y UTF-16).
    $rx = [regex]'(?i)\b[a-z0-9_\-]{2,40}\.(sys|dll|exe)\b'
    $nombres = New-Object System.Collections.Generic.HashSet[string]
    foreach ($enc in @([System.Text.Encoding]::ASCII, [System.Text.Encoding]::Unicode)) {
        $txt = $enc.GetString($bytes)
        foreach ($m in $rx.Matches($txt)) { [void]$nombres.Add($m.Value.ToLower()) }
    }

    # Solo los de TERCEROS son sospechosos reales (los de Microsoft son la víctima).
    $terceros = @()
    foreach ($n in $nombres) {
        $info = Get-DriverInfo $n
        if ($info -and $info.Compania -and ($info.Compania -notmatch 'Microsoft')) { $terceros += $info }
    }
    $terceros = @($terceros | Sort-Object Nombre -Unique)

    $clase = Clase-Bugcheck $res.Stop
    $orden = $terceros
    if ($clase -and $CLASE_HINTS.ContainsKey($clase)) {
        $hints = $CLASE_HINTS[$clase]
        $pref = @($terceros | Where-Object { $nm = $_.Nombre; ($hints | Where-Object { $nm -like "*$_*" }).Count -gt 0 })
        $resto = @($terceros | Where-Object { $pref -notcontains $_ })
        $orden = @($pref) + @($resto)
    }
    if ($orden.Count -gt 0) {
        $res.Culpable = $orden[0]
        $res.Sospechosos = $orden
        if ($clase -and ($CLASE_HINTS[$clase] | Where-Object { $res.Culpable.Nombre -like "*$_*" }).Count -gt 0) {
            $res.Confianza = 'alta'
        } else { $res.Confianza = 'media' }
    } else {
        $res.Nota = 'No se hallaron drivers de terceros en el volcado: el causante probable es un componente de Windows, y la causa de fondo suele ser hardware (RAM, disco o temperatura) o Windows danado.'
    }
    return $res
}

function Get-Minidumps {
    $dumps = @()
    foreach ($r in @("$env:SystemRoot\Minidump", "$env:SystemRoot")) {
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
        fix = 'Revisa temperaturas y limpia el equipo; prueba con otra fuente/regulador. Si el evento trae un código de bugcheck, es un pantallazo azul: revisa esa entrada.'
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

function Get-Eventos($filtro, $max) {
    try { return @(Get-WinEvent -FilterHashtable $filtro -MaxEvents $max -ErrorAction Stop) }
    catch { return @() }
}

# Acepta cualquier valor (algunos registros llegan sin fecha) para no reventar
# la recoleccion completa por un evento raro.
function Fecha($t) {
    if ($null -eq $t) { return '' }
    try { return ([datetime]$t).ToString('yyyy-MM-dd HH:mm:ss') } catch { return '' }
}

$items = New-Object System.Collections.ArrayList
$dumps = Get-Minidumps

# ---- 1) Pantallazos azules ---------------------------------------------------
$bsod = @()
foreach ($e in (Get-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $desde } 60)) {
    $msg = $e.Message; $stop = ''; $params = ''; $rutaDump = ''
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
    $bsod += [pscustomobject]@{ Cuando = $e.TimeCreated; Id = "bsod-41-$($e.RecordId)"; Fuente = "Evento 41 Kernel-Power"; Stop = $stop; Params = ''; Dump = ''; Mensaje = "$($e.Message)`r`n$extra" }
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
            cause = (Causa-Stop $stop); fix = $fix; detail = $detalle.ToString()
        })
}

# ---- 2) Resto de errores del registro (System + Application) -----------------
# Se agrupan por proveedor + Id: 40 veces el mismo error de disco es UN problema.
$grupos = @{}
$orden = New-Object System.Collections.ArrayList
$eventos = @()
$eventos += Get-Eventos @{ LogName = 'System'; Level = 1, 2; StartTime = $desde } $MaxEventos
$eventos += Get-Eventos @{ LogName = 'Application'; Level = 1, 2; StartTime = $desde } $MaxEventos

foreach ($e in $eventos) {
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
        detail = "$($e.Message)"
    }
    $grupos[$clave] = $item
    [void]$orden.Add($clave)
}
foreach ($k in $orden) {
    $g = $grupos[$k]
    if ([int]$g.count -le 1) { $g.firstWhen = '' }
    [void]$items.Add($g)
}

# ---- 3) Volcados presentes en el disco ---------------------------------------
$listaDumps = New-Object System.Collections.ArrayList
foreach ($d in ($dumps | Select-Object -First 30)) {
    [void]$listaDumps.Add([ordered]@{ path = $d.FullName; when = (Fecha $d.LastWriteTime); sizeBytes = [int64]$d.Length })
}
$memdmp = Join-Path $env:SystemRoot 'MEMORY.DMP'
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

$resultado = [ordered]@{
    ok       = $true
    elevated = $elevado
    items    = @($items)
    dumps    = @($listaDumps)
}
$json = $resultado | ConvertTo-Json -Depth 6
Set-Content -Path $Salida -Value $json -Encoding UTF8
