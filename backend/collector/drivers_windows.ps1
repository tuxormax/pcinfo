# Controladores de terceros y redes WiFi guardadas: inventario, respaldo y
# restauracion. Lo llama backend/collector/drivers_windows.go.
#
#   -Accion Listar              -Salida <json>   inventario (JSON al archivo)
#   -Accion RespaldarDrivers    -Carpeta <dir>   Export-WindowsDriver
#   -Accion RestaurarDrivers    -Carpeta <dir>   pnputil /add-driver /install
#   -Accion RespaldarWifi       -Carpeta <dir>   netsh wlan export (con clave)
#   -Accion RestaurarWifi       -Carpeta <dir>   netsh wlan add profile
#
# Las acciones de respaldo/restauracion IMPRIMEN una linea por elemento: el lado
# Go las lee en vivo y las muestra como avance. Cada linea lleva prefijo de
# nivel (OK:, AVISO:, ERROR:) para pintarla del color correcto.
#
# CUIDADO al tocar este archivo: PowerShell NO distingue mayusculas en los
# nombres de variable ($lista y $LISTA son la misma). Reutilizar un nombre pisa
# el valor anterior sin avisar (fue la causa del fallo del historial de errores
# en la Rev 29).
param(
    [Parameter(Mandatory = $true)][string]$Accion,
    [string]$Salida = '',
    [string]$Carpeta = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Ejecuta un comando EXTERNO (netsh, pnputil) con $ErrorActionPreference en
# Continue. Motivo: con "Stop" y la redireccion 2>&1, cualquier linea que el
# programa escriba en la salida de error se convierte en un error TERMINANTE y
# aborta el script — aunque el comando haya funcionado. pnputil escribe ahi los
# avisos de controladores que no aplican, que son normales.
function Nativo {
    param([Parameter(Mandatory = $true)][scriptblock]$Bloque)
    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Bloque } finally { $ErrorActionPreference = $previo }
}

function Escribe($nivel, $texto) {
    if ([string]::IsNullOrWhiteSpace($texto)) { return }
    Write-Output ("{0}:{1}" -f $nivel, $texto)
}

# ---------------------------------------------------------------- inventario --

# Redes WiFi guardadas. En vez de parsear la salida de "netsh wlan show
# profiles" —que viene TRADUCIDA al idioma del sistema y cambia de formato— se
# exportan los perfiles a una carpeta temporal y se leen sus XML, que son
# iguales en todos los idiomas. De paso el XML trae la contrasena.
function LeeRedes {
    $temporal = Join-Path $env:TEMP ("pcinfo-wifi-" + [guid]::NewGuid().ToString('N'))
    $redes = New-Object System.Collections.ArrayList
    try {
        New-Item -ItemType Directory -Path $temporal -Force | Out-Null
        # key=clear necesita administrador; sin el, se reintenta sin claves para
        # al menos poder LISTAR las redes.
        $null = Nativo { & netsh wlan export profile key=clear folder="$temporal" 2>&1 }
        if (-not (Get-ChildItem -Path $temporal -Filter *.xml -ErrorAction SilentlyContinue)) {
            $null = Nativo { & netsh wlan export profile folder="$temporal" 2>&1 }
        }
        foreach ($archivo in @(Get-ChildItem -Path $temporal -Filter *.xml -ErrorAction SilentlyContinue)) {
            try {
                [xml]$perfil = Get-Content -LiteralPath $archivo.FullName -Encoding UTF8
                [void]$redes.Add([pscustomobject][ordered]@{
                    name     = [string]$perfil.WLANProfile.name
                    auth     = [string]$perfil.WLANProfile.MSM.security.authEncryption.authentication
                    password = [string]$perfil.WLANProfile.MSM.security.sharedKey.keyMaterial
                })
            } catch { }
        }
    } catch {
    } finally {
        Remove-Item -LiteralPath $temporal -Recurse -Force -ErrorAction SilentlyContinue
    }
    return , @($redes)
}

# Controladores de terceros (los que trae Windows de fabrica no se listan: no se
# respaldan ni se restauran). Get-WindowsDriver -Online exige administrador.
function LeeControladores {
    $controladores = New-Object System.Collections.ArrayList
    foreach ($ctl in @(Get-WindowsDriver -Online)) {
        $fecha = ''
        if ($ctl.Date) { $fecha = ([datetime]$ctl.Date).ToString('yyyy-MM-dd') }
        [void]$controladores.Add([pscustomobject][ordered]@{
            name     = [string]$ctl.Driver
            original = [string]$ctl.OriginalFileName
            class    = [string]$ctl.ClassDescription
            provider = [string]$ctl.ProviderName
            version  = [string]$ctl.Version
            date     = $fecha
        })
    }
    return , @($controladores)
}

function Inventario {
    $reporte = [ordered]@{
        elevated = $false
        drivers  = @()
        wifi     = @()
        reason   = ''
    }
    $identidad = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $reporte.elevated = $identidad.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    try {
        $reporte.drivers = LeeControladores
    } catch {
        if ($reporte.elevated) {
            $reporte.reason = "No se pudo leer la lista de controladores: " + $_.Exception.Message
        } else {
            $reporte.reason = "Para ver y respaldar los controladores hace falta ejecutar PCInfo como administrador."
        }
    }
    try {
        $reporte.wifi = LeeRedes
    } catch { }

    $texto = ([pscustomobject]$reporte) | ConvertTo-Json -Depth 5 -Compress
    [System.IO.File]::WriteAllText($Salida, $texto, (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------- tareas --

function RespaldarDrivers {
    New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null
    $exportados = 0
    foreach ($ctl in @(Export-WindowsDriver -Online -Destination $Carpeta)) {
        $exportados++
        Escribe 'INFO' ("Exportado {0} ({1})" -f $ctl.OriginalFileName, $ctl.ClassName)
    }
    if ($exportados -eq 0) {
        Escribe 'AVISO' 'Windows no reporto ningun controlador de terceros que exportar.'
    } else {
        Escribe 'OK' ("{0} controladores exportados a {1}" -f $exportados, $Carpeta)
    }
}

function RestaurarDrivers {
    if (-not (Test-Path -LiteralPath $Carpeta)) {
        throw "No existe la carpeta de controladores del respaldo: $Carpeta"
    }
    $paquetes = @(Get-ChildItem -LiteralPath $Carpeta -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
    if ($paquetes.Count -eq 0) {
        throw "En $Carpeta no hay ningun archivo .inf: no parece un respaldo de controladores."
    }
    $bien = 0
    $mal = 0
    $reinicio = $false
    # Se instalan de uno en uno (y no con /subdirs de golpe) para poder decir
    # CUAL fallo: en un lote unico pnputil solo devuelve un codigo global.
    foreach ($paquete in $paquetes) {
        $null = Nativo { & pnputil.exe /add-driver "$($paquete.FullName)" /install 2>&1 }
        switch ($LASTEXITCODE) {
            0 {
                $bien++
                Escribe 'INFO' ("Instalado {0}" -f $paquete.Name)
            }
            3010 {
                $bien++
                $reinicio = $true
                Escribe 'INFO' ("Instalado {0} (pide reiniciar)" -f $paquete.Name)
            }
            default {
                $mal++
                Escribe 'AVISO' ("No se instalo {0} (codigo {1}); suele ser un controlador que ya esta o que no corresponde a este equipo." -f $paquete.Name, $LASTEXITCODE)
            }
        }
    }
    Escribe 'OK' ("{0} de {1} controladores instalados" -f $bien, $paquetes.Count)
    if ($mal -gt 0) { Escribe 'AVISO' ("{0} no se instalaron" -f $mal) }
    if ($reinicio) { Escribe 'AVISO' 'Alguno pide reiniciar el equipo para quedar activo.' }
    if ($bien -eq 0) { throw "Ningun controlador se pudo instalar." }
}

function RespaldarWifi {
    New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null
    # key=clear guarda la contrasena en el XML: es lo unico que permite despues
    # restaurar la red en otro equipo sin teclearla.
    $resultado = Nativo { & netsh wlan export profile key=clear folder="$Carpeta" 2>&1 }
    foreach ($linea in @($resultado)) {
        $texto = [string]$linea
        if (-not [string]::IsNullOrWhiteSpace($texto)) { Escribe 'INFO' $texto.Trim() }
    }
    $archivos = @(Get-ChildItem -LiteralPath $Carpeta -Filter *.xml -ErrorAction SilentlyContinue)
    if ($archivos.Count -eq 0) {
        throw "No se exporto ninguna red: el equipo no tiene redes WiFi guardadas o falta el adaptador inalambrico."
    }
    Escribe 'OK' ("{0} redes WiFi exportadas a {1}" -f $archivos.Count, $Carpeta)
}

function RestaurarWifi {
    if (-not (Test-Path -LiteralPath $Carpeta)) {
        throw "No existe la carpeta de redes del respaldo: $Carpeta"
    }
    $archivos = @(Get-ChildItem -LiteralPath $Carpeta -Filter *.xml -Recurse -ErrorAction SilentlyContinue)
    if ($archivos.Count -eq 0) {
        throw "En $Carpeta no hay ningun archivo .xml: no parece un respaldo de redes WiFi."
    }
    $bien = 0
    foreach ($archivo in $archivos) {
        $resultado = Nativo { & netsh wlan add profile filename="$($archivo.FullName)" user=all 2>&1 }
        if ($LASTEXITCODE -eq 0) {
            $bien++
            Escribe 'INFO' ("Anadida la red {0}" -f $archivo.BaseName)
        } else {
            Escribe 'AVISO' ("No se pudo anadir {0}: {1}" -f $archivo.Name, ([string]::Join(' ', @($resultado))).Trim())
        }
    }
    Escribe 'OK' ("{0} de {1} redes WiFi restauradas" -f $bien, $archivos.Count)
    if ($bien -eq 0) { throw "Ninguna red se pudo restaurar." }
}

switch ($Accion) {
    'Listar'            { Inventario }
    'RespaldarDrivers'  { RespaldarDrivers }
    'RestaurarDrivers'  { RestaurarDrivers }
    'RespaldarWifi'     { RespaldarWifi }
    'RestaurarWifi'     { RestaurarWifi }
    default             { throw "Accion desconocida: $Accion" }
}
