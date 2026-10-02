# VERSION: Windows 11 (sin tocar el registro) — script COMPLETO e independiente (no comparte archivos con la otra version).
# Instala apps de la Microsoft Store SIN abrir la Store: descarga los
# paquetes de Microsoft (vía store.rg-adguard.net, que solo recibe el
# ProductId) y los instala con Add-AppxPackage / DISM. Lo llama
# backend/collector/tienda_windows.go.
#
# Portado del script suelto www/windows/mitiendawindows/mitiendawindows.ps1
# (herramienta ya probada por tuxor): mismo "Núcleo" de trabajo, sin la GUI
# WinForms — la interfaz ahora es la pestaña "Tienda Windows" de PCInfo.
#
#   -Accion Buscar          -Consulta <texto> -Salida <json>
#   -Accion Instalar        -AppsArchivo <json> -Arch <a> -Ring <r> -Todos <bool>
#   -Accion InstalarCarpeta -Carpeta <dir>      -Arch <a>           -Todos <bool>
#
# Instalar/InstalarCarpeta IMPRIMEN una línea por paso, con el mismo prefijo de
# nivel que drivers_windows.ps1 (OK:, AVISO:, ERROR:, INFO:): el lado Go las
# lee en vivo y las muestra como avance de la tarea.
#
# Las dependencias (frameworks: VCLibs, .NET Native, UI.Xaml, WindowsAppRuntime…)
# se cachean por nombre EXACTO en C:\seismexico\pcinfo\tienda-frameworks para
# no volver a descargarlas en cada app — ver Get-Paquete/Get-CarpetaCacheFrameworks.
# Toda carpeta de PCInfo en Windows (cache, instalacion, lo que se agregue
# despues) vive bajo C:\seismexico\pcinfo — ver Get-CarpetaBaseSeis.
param(
    [Parameter(Mandatory = $true)][string]$Accion,
    [string]$Consulta = '',
    [string]$Salida = '',
    [string]$AppsArchivo = '',
    [string]$Carpeta = '',
    [ValidateSet('Auto', 'x64', 'x86', 'arm64')][string]$Arch = 'Auto',
    [ValidateSet('Retail', 'RP', 'WIS', 'WIF')][string]$Ring = 'Retail',
    [string]$Todos = 'true'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Escribe {
    param([string]$Nivel, [string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return }
    Write-Output ("{0}:{1}" -f $Nivel, $Texto)
}

# ===================================================================
#  NUCLEO — portado de mitiendawindows.ps1 (mismo comportamiento)
# ===================================================================

function Get-ProductId {
    param([string]$Texto)
    $t = ($Texto -replace '\s', '')
    if (-not $t) { throw "No se dio ningun enlace ni ProductId." }
    if ($t -match '^[A-Za-z0-9]{12,14}$') { return $t.ToUpper() }
    $m = [regex]::Match($t, '(?i)(?:productid=|/detail/|/productId/|/apps/|/store/apps/|/p/[^/]+/)([A-Za-z0-9]{12,14})')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    $m = [regex]::Match($t, '(?i)\b([9Xx][A-Za-z0-9]{11,13})\b')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    throw "No se pudo sacar el ProductId de: $Texto"
}

function Get-Arquitectura {
    param([string]$Pedida = 'Auto')
    if ($Pedida -and $Pedida -ne 'Auto') { return $Pedida.ToLower() }
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'x86'   { if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { return 'x64' } else { return 'x86' } }
        default { return 'x64' }
    }
}

function Get-MensajeCloudflare {
    return "rg-adguard esta protegido por Cloudflare y bloqueo la peticion (reto " +
        "'Just a moment'). No es un fallo de PCInfo. Abre https://store.rg-adguard.net " +
        "en el navegador de este equipo, deja que pase la verificacion y reintenta. " +
        "Si sigue fallando, descarga ahi mismo los .appx/.msixbundle a mano e instalalos " +
        "con 'Instalar desde carpeta'."
}

function Get-ArchivosStore {
    param([string]$ProductId, [string]$Ring = 'Retail')

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch { }

    $cuerpo = "type=ProductId&url=$ProductId&ring=$Ring&lang=es-MX"
    Escribe 'INFO' "Consultando store.rg-adguard.net (ProductId $ProductId, canal $Ring)..."

    $html = $null
    try {
        $r = Invoke-WebRequest -Uri 'https://store.rg-adguard.net/api/GetFiles' `
                               -Method Post -Body $cuerpo `
                               -ContentType 'application/x-www-form-urlencoded' `
                               -Headers @{ 'Accept-Language' = 'es-MX,es;q=0.9,en;q=0.8'; 'Referer' = 'https://store.rg-adguard.net/' } `
                               -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' `
                               -UseBasicParsing -TimeoutSec 90
        $html = $r.Content
    } catch {
        $cuerpoError = ''
        try {
            $resp = $_.Exception.Response
            if ($resp) {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $cuerpoError = $sr.ReadToEnd(); $sr.Close()
            }
        } catch { }
        if ($cuerpoError -match '(?i)just a moment|cf-chl|challenges\.cloudflare\.com|attention required') {
            throw (Get-MensajeCloudflare)
        }
        throw "No se pudo contactar a rg-adguard: $($_.Exception.Message). Revisa la conexion o reintenta en unos minutos."
    }

    if ($html -match '(?i)just a moment|cf-chl|challenges\.cloudflare\.com|attention required') {
        throw (Get-MensajeCloudflare)
    }
    if ($html -match '(?i)captcha|too many requests|rate limit') {
        throw "rg-adguard esta limitando las peticiones. Espera unos minutos y reintenta."
    }
    if ($html -match '(?i)server returned an empty list|nothing was found|the value entered is not valid') {
        throw "rg-adguard no devolvio archivos para ese ProductId. Verifica el enlace o prueba con otro canal (RP)."
    }

    $rx = [regex]'(?is)<a\s+href=["''](?<u>https?://[^"'']+)["''][^>]*>(?<n>[^<]+)</a>'
    $lista = @()
    foreach ($m in $rx.Matches($html)) {
        $lista += [pscustomobject]@{ Nombre = $m.Groups['n'].Value.Trim(); Url = $m.Groups['u'].Value }
    }
    if (-not $lista.Count) { throw "rg-adguard respondio pero sin enlaces de descarga. Reintenta en unos minutos." }
    Escribe 'INFO' "rg-adguard devolvio $($lista.Count) archivo(s)."
    return $lista
}

function Split-NombrePaquete {
    param([string]$Nombre)
    $ext = [System.IO.Path]::GetExtension($Nombre)
    $p = $Nombre.Split('_')
    $ver = $null
    if ($p.Count -ge 2) { try { $ver = [version]$p[1] } catch { $ver = $null } }
    if (-not $ver) { $ver = [version]'0.0.0.0' }
    $arch = 'neutral'
    if ($p.Count -ge 3 -and $p[2]) { $arch = $p[2].ToLower() }
    [pscustomobject]@{ Paquete = $p[0]; Version = $ver; Arch = $arch; Extension = $ext.ToLower() }
}

function Select-Paquetes {
    param($Archivos, [string]$Arch)

    $validos = @('.appx', '.appxbundle', '.msix', '.msixbundle')
    $rxDep   = '^Microsoft\.(VCLibs|NET\.Native\.Framework|NET\.Native\.Runtime|UI\.Xaml|Services\.Store\.Engagement|WindowsAppRuntime|DirectXRuntime)'
    $elegidos = @()

    $candidatos = @()
    foreach ($a in $Archivos) {
        if ($a.Nombre -match '(?i)\.blockmap$|\.appxsym$|\.cat$|\.xml$') { continue }
        $info = Split-NombrePaquete $a.Nombre
        if ($validos -notcontains $info.Extension) { continue }
        if ($info.Arch -ne $Arch -and $info.Arch -ne 'neutral' -and $info.Arch -ne 'all') { continue }
        $candidatos += [pscustomobject]@{
            Nombre = $a.Nombre; Url = $a.Url; Paquete = $info.Paquete
            Version = $info.Version; Arch = $info.Arch; EsDep = ($info.Paquete -match $rxDep)
        }
    }
    if (-not $candidatos.Count) { throw "No hay paquetes compatibles con la arquitectura $Arch en la respuesta de rg-adguard." }

    foreach ($g in ($candidatos | Group-Object { "$($_.Paquete)|$($_.Arch)" })) {
        $elegidos += ($g.Group | Sort-Object Version -Descending | Select-Object -First 1)
    }

    $deps = @($elegidos | Where-Object { $_.EsDep }  | Sort-Object Paquete)
    $apps = @($elegidos | Where-Object { -not $_.EsDep } | Sort-Object Version -Descending)
    if (-not $apps.Count) { throw "Se encontraron dependencias pero no el paquete principal de la app." }
    if ($apps.Count -gt 1) {
        foreach ($x in $apps[1..($apps.Count - 1)]) {
            Escribe 'AVISO' ("Se omite paquete extra: {0}" -f $x.Nombre)
        }
        $apps = @($apps[0])
    }
    Escribe 'INFO' ("Arquitectura: {0}  |  Dependencias: {1}  |  App: {2}" -f $Arch, $deps.Count, $apps[0].Paquete)
    return @{ Deps = $deps; App = $apps[0]; Todos = @($deps + $apps) }
}

function Invoke-Descarga {
    param([string]$Url, [string]$Destino, [string]$Etiqueta)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch { }

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 120000
    $resp = $req.GetResponse()
    $entrada = $resp.GetResponseStream()
    $salida = [System.IO.File]::Create($Destino)
    try {
        $buffer = New-Object byte[] 262144
        while (($n = $entrada.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $salida.Write($buffer, 0, $n)
        }
    } finally {
        $salida.Close(); $entrada.Close(); $resp.Close()
    }
    $mb = [math]::Round((Get-Item $Destino).Length / 1MB, 1)
    Escribe 'OK' ("{0} ({1} MB)" -f $Etiqueta, $mb)
}

# --- Cache de dependencias (frameworks compartidos) ---------------------
# Casi cualquier app de la Tienda pide los mismos frameworks (VCLibs, .NET
# Native Framework/Runtime, UI.Xaml —hay varias versiones mayores distintas,
# 2.0/2.1/2.4/2.7/2.8, cada una un paquete con nombre propio—,
# WindowsAppRuntime, Services.Store.Engagement, DirectXRuntime). Sin cache,
# instalar dos apps seguidas puede bajar ~150 MB de los MISMOS frameworks dos
# veces. La APP PRINCIPAL nunca se cachea: pesa mucho, es especifica de cada
# instalacion y no se repite entre apps.
#
# Se cachea por el NOMBRE EXACTO del archivo (Nombre_Version_Arch_Publisher,
# tal cual lo entrega el origen de descarga), nunca por el nombre corto del
# paquete ("UI.Xaml" sin version): dos apps pueden pedir versiones distintas
# del MISMO framework, y mezclarlas hace que Add-AppxPackage falle con
# 0x80073CF3 ("was provided but not used") — el manifiesto de la app exige el
# juego EXACTO de dependencias que declara, ni una de mas ni una de menos.
#
# Carpeta: C:\seismexico\pcinfo\tienda-frameworks — mismo convenio que ya usan
# las demas herramientas de seismexico (ej. el arreglador guarda su bitacora,
# respaldo y estado bajo C:\seismexico\<herramienta>): una ruta fija, la MISMA
# para cualquier cuenta de usuario o nivel de elevacion, facil de encontrar y
# de limpiar a mano en un equipo de cliente. Sobrevive entre ejecuciones y
# entre reinstalaciones de PCInfo; no se borra sola. Requiere administrador
# para crearse bajo la raiz de C:\ — este modulo ya lo exige siempre.
function Get-CarpetaBaseSeis {
    $carpeta = 'C:\seismexico\pcinfo'
    New-Item -ItemType Directory -Path $carpeta -Force -ErrorAction SilentlyContinue | Out-Null
    return $carpeta
}

function Get-CarpetaCacheFrameworks {
    $carpeta = Join-Path (Get-CarpetaBaseSeis) 'tienda-frameworks'
    New-Item -ItemType Directory -Path $carpeta -Force -ErrorAction SilentlyContinue | Out-Null
    return $carpeta
}

# Resuelve un paquete de la lista de descarga: si es una dependencia y ya
# esta en la cache (mismo nombre exacto), reutiliza esa copia sin descargar
# nada; si no, descarga a la carpeta de trabajo y, si es dependencia, guarda
# una copia en la cache para la proxima vez. La app principal ($EsDep=$false)
# siempre se descarga a la carpeta de trabajo, nunca toca la cache.
function Get-Paquete {
    param([string]$Url, [string]$CarpetaTrabajo, [string]$Nombre, [bool]$EsDep)

    if ($EsDep) {
        $cacheado = Join-Path (Get-CarpetaCacheFrameworks) $Nombre
        if (Test-Path -LiteralPath $cacheado) {
            $mb = [math]::Round((Get-Item -LiteralPath $cacheado).Length / 1MB, 1)
            Escribe 'OK' ("{0} ({1} MB, ya en cache — no se vuelve a descargar)" -f $Nombre, $mb)
            return $cacheado
        }
    }

    Escribe 'INFO' ("Descargando {0}" -f $Nombre)
    $destino = Join-Path $CarpetaTrabajo $Nombre
    Invoke-Descarga -Url $Url -Destino $destino -Etiqueta $Nombre

    if ($EsDep) {
        try {
            Copy-Item -LiteralPath $destino -Destination (Join-Path (Get-CarpetaCacheFrameworks) $Nombre) -Force -ErrorAction Stop
        } catch {
            Escribe 'AVISO' ("No se pudo guardar {0} en la cache de frameworks: {1}" -f $Nombre, $_.Exception.Message)
        }
    }
    return $destino
}

function Install-Dependencia {
    param([string]$Ruta, [string]$Nombre)
    try {
        Add-AppxPackage -Path $Ruta -ErrorAction Stop
        Escribe 'OK' ("Dependencia instalada: {0}" -f $Nombre)
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '0x80073D06|higher version|already installed') {
            Escribe 'AVISO' ("{0}: ya hay una version igual o mas nueva, se omite." -f $Nombre)
        } else {
            Escribe 'AVISO' ("{0}: {1}" -f $Nombre, $msg)
        }
    }
}

function Install-App {
    param([string]$Ruta, [string]$Nombre, [string[]]$Dependencias, [bool]$TodosLosUsuarios)
    try {
        if ($Dependencias -and $Dependencias.Count) {
            Add-AppxPackage -Path $Ruta -DependencyPath $Dependencias -ErrorAction Stop
        } else {
            Add-AppxPackage -Path $Ruta -ErrorAction Stop
        }
        Escribe 'OK' ("App instalada para el usuario actual: {0}" -f $Nombre)
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '0x80073D06|higher version|already installed') {
            Escribe 'AVISO' "La app ya estaba instalada en esta cuenta (version igual o mas nueva)."
        } else {
            throw "No se pudo instalar la app: $msg"
        }
    }

    if (-not $TodosLosUsuarios) {
        Escribe 'INFO' "Se omitio la provision para todos los usuarios."
        return
    }
    Escribe 'INFO' "Provisionando para TODOS los usuarios (DISM)..."
    try {
        $p = @{ Online = $true; PackagePath = $Ruta; SkipLicense = $true; ErrorAction = 'Stop' }
        if ($Dependencias -and $Dependencias.Count) { $p['DependencyPackagePath'] = $Dependencias }
        Add-AppxProvisionedPackage @p | Out-Null
        Escribe 'OK' "Provisionada: se instalara sola en cada cuenta nueva."
    } catch {
        Escribe 'AVISO' ("No se pudo provisionar para todos los usuarios: {0}" -f $_.Exception.Message)
        Escribe 'AVISO' "La app SI quedo instalada en la cuenta actual."
    }
}

function Start-Instalacion {
    param([string]$Url, [string]$Arch = 'Auto', [string]$Ring = 'Retail', [bool]$TodosLosUsuarios = $true)

    $id    = Get-ProductId $Url
    $arqui = Get-Arquitectura $Arch
    $lista = Get-ArchivosStore -ProductId $id -Ring $Ring
    $sel   = Select-Paquetes -Archivos $lista -Arch $arqui

    # Carpeta de trabajo (descargas a medio instalar), TAMBIEN bajo
    # C:\seismexico\pcinfo — no en $env:TEMP, por el mismo motivo que la cache
    # de frameworks: una ruta fija y predecible en vez de una por usuario.
    $carpeta = Join-Path (Get-CarpetaBaseSeis) "tienda-instalacion\$id"
    if (Test-Path $carpeta) { Remove-Item $carpeta -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $carpeta -Force | Out-Null

    $rutasDeps = @()
    $rutaApp = $null
    foreach ($p in $sel.Todos) {
        $ruta = Get-Paquete -Url $p.Url -CarpetaTrabajo $carpeta -Nombre $p.Nombre -EsDep $p.EsDep
        if ($p.EsDep) { $rutasDeps += $ruta } else { $rutaApp = $ruta }
    }

    Escribe 'INFO' "Instalando dependencias..."
    foreach ($d in $rutasDeps) { Install-Dependencia -Ruta $d -Nombre ([System.IO.Path]::GetFileName($d)) }

    Escribe 'INFO' "Instalando la app..."
    Install-App -Ruta $rutaApp -Nombre $sel.App.Paquete -Dependencias $rutasDeps -TodosLosUsuarios $TodosLosUsuarios

    Remove-Item $carpeta -Recurse -Force -ErrorAction SilentlyContinue
    Escribe 'OK' ("LISTO: {0} instalada." -f $sel.App.Paquete)
}

function Start-InstalacionLocal {
    param([string]$Carpeta, [string]$Arch = 'Auto', [bool]$TodosLosUsuarios = $true)

    if (-not (Test-Path $Carpeta)) { throw "No existe la carpeta: $Carpeta" }
    $arqui = Get-Arquitectura $Arch

    $archivos = @()
    foreach ($f in (Get-ChildItem -Path $Carpeta -File)) {
        $archivos += [pscustomobject]@{ Nombre = $f.Name; Url = $f.FullName }
    }
    if (-not $archivos.Count) { throw "La carpeta esta vacia: $Carpeta" }

    Escribe 'INFO' ("Leyendo paquetes de: {0}" -f $Carpeta)
    $sel = Select-Paquetes -Archivos $archivos -Arch $arqui
    $rutasDeps = @($sel.Deps | ForEach-Object { $_.Url })

    Escribe 'INFO' "Instalando dependencias..."
    foreach ($d in $rutasDeps) { Install-Dependencia -Ruta $d -Nombre ([System.IO.Path]::GetFileName($d)) }

    Escribe 'INFO' "Instalando la app..."
    Install-App -Ruta $sel.App.Url -Nombre $sel.App.Paquete -Dependencias $rutasDeps -TodosLosUsuarios $TodosLosUsuarios
    Escribe 'OK' ("LISTO: {0} instalada." -f $sel.App.Paquete)
}

function Search-Store {
    param([string]$Consulta, [string]$Mercado = 'MX', [string]$Idioma = 'es-MX')

    $q = ($Consulta -replace '\s', ' ').Trim()
    if (-not $q) { throw "Escribe algo para buscar." }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch { }

    $uri = "https://storeedgefd.dsx.mp.microsoft.com/v8.0/search?market=$Mercado&locale=$Idioma&query=$([uri]::EscapeDataString($q))&mediaType=apps"
    try {
        $r = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 20 `
                               -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
        $d = $r.Content | ConvertFrom-Json
    } catch {
        throw "No se pudo buscar en la Store: $($_.Exception.Message)"
    }

    $out = @()
    foreach ($c in @($d.Payload.Cards)) {
        if ($c.TypeTag -ne 'app' -and $c.TypeTag -ne 'game') { continue }
        if (-not $c.ProductId) { continue }
        $out += [pscustomobject]@{ nombre = $c.Title; publisher = $c.PublisherName; productId = $c.ProductId }
    }
    return , @($out)
}

function Start-InstalacionMultiple {
    param([object[]]$Apps, [string]$Arch = 'Auto', [string]$Ring = 'Retail', [bool]$TodosLosUsuarios = $true)

    if (-not $Apps -or -not $Apps.Count) { throw "La lista de apps esta vacia." }
    $exitosas = 0
    $fallidas = @()
    $i = 0
    foreach ($a in $Apps) {
        $i++
        Escribe 'INFO' ("===== ({0}/{1}) {2} =====" -f $i, $Apps.Count, $a.nombre)
        try {
            Start-Instalacion -Url $a.productId -Arch $Arch -Ring $Ring -TodosLosUsuarios $TodosLosUsuarios
            $exitosas++
        } catch {
            Escribe 'ERROR' ("{0}: {1}" -f $a.nombre, $_.Exception.Message)
            $fallidas += $a.nombre
        }
    }
    if ($fallidas.Count) {
        Escribe 'AVISO' ("LISTO con errores: {0} de {1} instaladas. Fallaron: {2}" -f $exitosas, $Apps.Count, ($fallidas -join ', '))
        if ($exitosas -eq 0) { throw "Ninguna app se pudo instalar." }
    } else {
        Escribe 'OK' ("LISTO: {0} de {1} apps instaladas." -f $exitosas, $Apps.Count)
    }
}

# ===================================================================
#  Acciones
# ===================================================================

switch ($Accion) {
    'Buscar' {
        $res = @(Search-Store -Consulta $Consulta)
        $texto = (, $res) | ConvertTo-Json -Depth 5 -Compress
        [System.IO.File]::WriteAllText($Salida, $texto, (New-Object System.Text.UTF8Encoding($false)))
    }
    'Instalar' {
        if (-not (Test-Path -LiteralPath $AppsArchivo)) { throw "No se encontro la lista de apps a instalar." }
        $apps = Get-Content -LiteralPath $AppsArchivo -Raw -Encoding UTF8 | ConvertFrom-Json
        Start-InstalacionMultiple -Apps @($apps) -Arch $Arch -Ring $Ring -TodosLosUsuarios ([bool]::Parse($Todos))
    }
    'InstalarCarpeta' {
        Start-InstalacionLocal -Carpeta $Carpeta -Arch $Arch -TodosLosUsuarios ([bool]::Parse($Todos))
    }
    default { throw "Accion desconocida: $Accion" }
}
