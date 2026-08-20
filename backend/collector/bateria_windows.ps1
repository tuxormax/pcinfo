# Informe de bateria para PCInfo (Windows). Escribe un JSON en -Salida.
# Lo llama backend/collector/bateria_windows.go.
#
# Fuentes:
#   1. powercfg /batteryreport /xml  -> capacidad de fabrica, capacidad actual,
#      ciclos, historial semana a semana y estimaciones de duracion. Es el MISMO
#      informe que Windows ensena en HTML, pero el XML no esta traducido a otros
#      idiomas: los nombres de los campos son fijos, el HTML no.
#   2. WMI (Win32_Battery y root\WMI) -> el estado de ESTE momento: porcentaje,
#      si esta cargando y si el equipo esta enchufado. Tambien sirve de respaldo
#      si powercfg no pudo generar el informe.
#
# CUIDADO: PowerShell NO distingue mayusculas en los nombres de variable
# ($lista y $LISTA son la misma). Reutilizar un nombre pisa el valor anterior sin
# avisar (fue la causa del fallo del historial de errores en la Rev 29).
param(
    [Parameter(Mandatory = $true)][string]$Salida
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Texto($valor) {
    if ($null -eq $valor) { return '' }
    return ([string]$valor).Trim()
}

function Entero($valor) {
    $limpio = (Texto $valor) -replace '[^\d\-]', ''
    if ($limpio -eq '' -or $limpio -eq '-') { return 0 }
    try { return [int]$limpio } catch { return 0 }
}

# Busca un dato por NOMBRE dentro de un nodo, venga como elemento hijo o como
# atributo. El esquema del informe ha cambiado entre versiones de Windows y los
# mismos datos aparecen unas veces como etiqueta y otras como atributo; buscar
# por nombre evita depender de la forma exacta del XML.
function Valor($nodo, [string[]]$nombres) {
    foreach ($clave in $nombres) {
        $elemento = $nodo.SelectSingleNode(".//*[local-name()='$clave']")
        if ($elemento -and (Texto $elemento.InnerText) -ne '') { return (Texto $elemento.InnerText) }
        $propio = $nodo.SelectSingleNode("@*[local-name()='$clave']")
        if ($propio) { return (Texto $propio.Value) }
        $hondo = $nodo.SelectSingleNode(".//@*[local-name()='$clave']")
        if ($hondo) { return (Texto $hondo.Value) }
    }
    return ''
}

# Minutos de una duracion ISO 8601 ("PT6H8M58S"). 0 si no lo es.
function Minutos($texto) {
    $crudo = Texto $texto
    if ($crudo -notmatch '^P') { return 0 }
    try { return [int][System.Xml.XmlConvert]::ToTimeSpan($crudo).TotalMinutes } catch { return 0 }
}

$aviso = ''
$documento = $null
$temporal = Join-Path $env:TEMP ("pcinfo-bateria-" + [guid]::NewGuid().ToString('N') + ".xml")
try {
    $vozPowercfg = (& powercfg.exe /batteryreport /xml /output $temporal 2>&1 | Out-String)
    if (Test-Path -LiteralPath $temporal) {
        $documento = [xml](Get-Content -LiteralPath $temporal -Raw)
    } else {
        $aviso = 'Windows no pudo generar su informe de bateria. ' + (Texto $vozPowercfg)
    }
} catch {
    $aviso = 'Fallo al generar el informe de bateria de Windows: ' + $_.Exception.Message
} finally {
    Remove-Item -LiteralPath $temporal -Force -ErrorAction SilentlyContinue
}

# --- Baterias instaladas -----------------------------------------------------
$listaBaterias = New-Object System.Collections.ArrayList
if ($documento) {
    foreach ($nodoBateria in $documento.SelectNodes("//*[local-name()='Battery']")) {
        $fila = [ordered]@{
            id          = (Valor $nodoBateria @('Id', 'Name', 'DeviceName'))
            fabricante  = (Valor $nodoBateria @('Manufacturer', 'ManufactureName'))
            serie       = (Valor $nodoBateria @('SerialNumber'))
            quimica     = (Valor $nodoBateria @('Chemistry'))
            disenoMWh   = (Entero (Valor $nodoBateria @('DesignCapacity', 'DesignedCapacity')))
            llenaMWh    = (Entero (Valor $nodoBateria @('FullChargeCapacity', 'FullChargedCapacity')))
            ciclos      = (Entero (Valor $nodoBateria @('CycleCount')))
        }
        [void]$listaBaterias.Add([pscustomobject]$fila)
    }
}

# --- Historial de capacidad (una fila por periodo) ---------------------------
$listaHistorial = New-Object System.Collections.ArrayList
if ($documento) {
    foreach ($nodoPeriodo in $documento.SelectNodes("//*[local-name()='HistoryEntry']")) {
        $capacidadLlena = Entero (Valor $nodoPeriodo @('FullChargeCapacity'))
        $capacidadDiseno = Entero (Valor $nodoPeriodo @('DesignCapacity'))
        # Las entradas de uso (horas en corriente/bateria) no traen capacidad: se
        # saltan. Solo interesa la curva de desgaste.
        if ($capacidadLlena -le 0 -and $capacidadDiseno -le 0) { continue }
        $fila = [ordered]@{
            inicio    = (Valor $nodoPeriodo @('StartDate'))
            fin       = (Valor $nodoPeriodo @('EndDate'))
            llenaMWh  = $capacidadLlena
            disenoMWh = $capacidadDiseno
        }
        [void]$listaHistorial.Add([pscustomobject]$fila)
    }
}

# --- Estimaciones de duracion ------------------------------------------------
# Se localiza por el VALOR, no por el nombre del campo: una duracion ISO 8601
# ("PT6H8M58S") no se confunde con nada mas. Solo interesa la de "carga
# completa"; se descartan las de suspension conectada (Cs / Standby), que son
# otra medida, y la de capacidad de fabrica, que no se muestra a proposito
# (ver el comentario de RuntimeFullMin en bateria.go).
$minutosLlena = 0
if ($documento) {
    $candidatos = New-Object System.Collections.ArrayList
    foreach ($atributo in $documento.SelectNodes("//@*")) {
        [void]$candidatos.Add(@{ nombre = $atributo.LocalName; valor = (Texto $atributo.Value) })
    }
    foreach ($elemento in $documento.SelectNodes("//*")) {
        if ($elemento.SelectNodes("*").Count -eq 0) {
            [void]$candidatos.Add(@{ nombre = $elemento.LocalName; valor = (Texto $elemento.InnerText) })
        }
    }
    foreach ($opcion in $candidatos) {
        $duracion = Minutos $opcion.valor
        if ($duracion -le 0) { continue }
        $nombreCampo = [string]$opcion.nombre
        if ($nombreCampo -match '(?i)cs|standby') { continue }
        if ($nombreCampo -match '(?i)design') { continue }
        if ($nombreCampo -match '(?i)full') { $minutosLlena = $duracion }
    }
}

# --- Estado de este momento (WMI) --------------------------------------------
$vivo = [ordered]@{
    porcentaje    = -1
    estado        = ''
    enCA          = $false
    enCAConocido  = $false
    minutos       = 0
    restanteMWh   = 0
    ciclosWmi     = -1
    disenoWmi     = 0
    llenaWmi      = 0
    voltajeMV     = 0
    quimicaWmi    = ''
    nombreWmi     = ''
    modeloWmi     = ''
    fabricanteWmi = ''
    serieWmi      = ''
}

try {
    $wmiBateria = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
    if ($wmiBateria) {
        if ($null -ne $wmiBateria.EstimatedChargeRemaining) {
            $vivo.porcentaje = [int]$wmiBateria.EstimatedChargeRemaining
        }
        $codigoEstado = [int]$wmiBateria.BatteryStatus
        $vivo.estado = switch ($codigoEstado) {
            1 { 'descargando' }
            2 { 'conectada' }
            3 { 'llena' }
            4 { 'descargando' }
            5 { 'descargando' }
            6 { 'cargando' }
            7 { 'cargando' }
            8 { 'cargando' }
            9 { 'cargando' }
            11 { 'conectada' }
            default { '' }
        }
        $vivo.enCAConocido = $true
        $vivo.enCA = ($codigoEstado -ne 1 -and $codigoEstado -ne 4 -and $codigoEstado -ne 5)
        # EstimatedRunTime devuelve 71582788 (sin limite) cuando esta enchufado.
        $restanMinutos = [int64]$wmiBateria.EstimatedRunTime
        if ($restanMinutos -gt 0 -and $restanMinutos -lt 6000) { $vivo.minutos = [int]$restanMinutos }
        $vivo.nombreWmi = Texto $wmiBateria.Name
        $vivo.voltajeMV = Entero $wmiBateria.DesignVoltage
        $vivo.quimicaWmi = switch ([int]$wmiBateria.Chemistry) {
            3 { 'PbAc' }
            4 { 'NiCd' }
            5 { 'NiMH' }
            6 { 'LION' }
            7 { 'ZnAir' }
            8 { 'LiP' }
            default { '' }
        }
    }
} catch { }

# root\WMI trae los datos que Win32_Battery no da (capacidad real y ciclos). No
# todos los portatiles publican estas clases: cada una en su propio try.
try {
    $estaticos = Get-CimInstance -Namespace 'root\WMI' -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1
    if ($estaticos) {
        $vivo.disenoWmi = Entero $estaticos.DesignedCapacity
        if ($estaticos.Chemistry) { $vivo.quimicaWmi = (Texto (-join ([char[]]($estaticos.Chemistry)))) }
        $vivo.fabricanteWmi = Texto $estaticos.ManufactureName
        $vivo.serieWmi = Texto $estaticos.SerialNumber
        # DeviceName es la referencia de la pieza en muchos portatiles
        # (L15M4PC0, 45N1049): es el dato con el que se compra el repuesto.
        $vivo.modeloWmi = Texto $estaticos.DeviceName
    }
} catch { }

try {
    $capacidadPlena = Get-CimInstance -Namespace 'root\WMI' -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
    if ($capacidadPlena) { $vivo.llenaWmi = Entero $capacidadPlena.FullChargedCapacity }
} catch { }

try {
    $cuentaCiclos = Get-CimInstance -Namespace 'root\WMI' -ClassName BatteryCycleCount -ErrorAction Stop | Select-Object -First 1
    if ($cuentaCiclos) { $vivo.ciclosWmi = Entero $cuentaCiclos.CycleCount }
} catch { }

try {
    $estadoVivo = Get-CimInstance -Namespace 'root\WMI' -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
    if ($estadoVivo) {
        $vivo.restanteMWh = Entero $estadoVivo.RemainingCapacity
        if ($vivo.voltajeMV -le 0) { $vivo.voltajeMV = Entero $estadoVivo.Voltage }
        $vivo.enCA = [bool]$estadoVivo.PowerOnline
        $vivo.enCAConocido = $true
        if ([bool]$estadoVivo.Charging) { $vivo.estado = 'cargando' }
        elseif ([bool]$estadoVivo.Discharging) { $vivo.estado = 'descargando' }
        elseif ([bool]$estadoVivo.PowerOnline -and $vivo.porcentaje -ge 99) { $vivo.estado = 'llena' }
        elseif ([bool]$estadoVivo.PowerOnline) { $vivo.estado = 'conectada' }
    }
} catch { }

$resultado = [ordered]@{
    aviso        = $aviso
    generado     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    baterias     = @($listaBaterias)
    historial    = @($listaHistorial)
    estimaciones = [ordered]@{ llenaMin = $minutosLlena }
    vivo         = $vivo
}

$json = $resultado | ConvertTo-Json -Depth 6 -Compress
[System.IO.File]::WriteAllText($Salida, $json, (New-Object System.Text.UTF8Encoding($false)))
