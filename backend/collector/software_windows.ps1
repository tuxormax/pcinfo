# Apps de la Tienda (Appx/MSIX) del usuario actual, en JSON.
# Lo llama backend/collector/software_windows.go; los programas clasicos los lee
# Go directamente del registro (mas rapido y sin depender de PowerShell).
#
# CUIDADO al tocar este archivo: PowerShell NO distingue mayusculas en los
# nombres de variable ($lista y $LISTA son la misma). Reutilizar un nombre pisa
# el valor anterior sin avisar (fue la causa del fallo del historial de errores
# en la Rev 29).
param(
    [Parameter(Mandatory = $true)][string]$Salida
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Nombres bonitos: Get-StartApps da el nombre que se ve en el menu Inicio, con
# AppID = "<PackageFamilyName>!<Id>". Sin esto muchas apps saldrian con su
# nombre interno (Microsoft.WindowsCalculator) o con un "ms-resource:..." sin
# resolver, porque el DisplayName del manifiesto suele ser una referencia.
$amigables = @{}
foreach ($atajo in @(Get-StartApps)) {
    $identificador = [string]$atajo.AppID
    $corte = $identificador.IndexOf('!')
    if ($corte -gt 0) {
        $familia = $identificador.Substring(0, $corte)
        if (-not $amigables.ContainsKey($familia)) {
            $amigables[$familia] = [string]$atajo.Name
        }
    }
}

$resultado = New-Object System.Collections.ArrayList

foreach ($paquete in @(Get-AppxPackage)) {
    $familia = [string]$paquete.PackageFamilyName
    $nombre = $null
    if ($amigables.ContainsKey($familia)) { $nombre = $amigables[$familia] }
    if ([string]::IsNullOrWhiteSpace($nombre)) {
        try {
            $manifiesto = Get-AppxPackageManifest $paquete
            $visible = [string]$manifiesto.Package.Properties.DisplayName
            if ($visible -and -not $visible.StartsWith('ms-resource')) { $nombre = $visible }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($nombre)) {
        $interno = [string]$paquete.Name
        $punto = $interno.LastIndexOf('.')
        if ($punto -ge 0 -and $punto -lt ($interno.Length - 1)) {
            $nombre = $interno.Substring($punto + 1)
        } else {
            $nombre = $interno
        }
    }

    # El publisher viene como cadena de certificado: "CN=Microsoft Corporation, O=..."
    $fabricante = [string]$paquete.Publisher
    foreach ($parte in ($fabricante -split ',')) {
        $limpio = $parte.Trim()
        if ($limpio.StartsWith('CN=')) { $fabricante = $limpio.Substring(3); break }
    }

    $fila = [ordered]@{
        name          = $nombre
        version       = [string]$paquete.Version
        publisher     = $fabricante
        arch          = [string]$paquete.Architecture
        location      = [string]$paquete.InstallLocation
        packageName   = [string]$paquete.Name
        packageFullName = [string]$paquete.PackageFullName
        signatureKind = [string]$paquete.SignatureKind
        isFramework   = [bool]$paquete.IsFramework
        nonRemovable  = [bool]$paquete.NonRemovable
    }
    [void]$resultado.Add([pscustomobject]$fila)
}

# ConvertTo-Json colapsa una lista de un solo elemento en un objeto suelto, y el
# lado Go espera SIEMPRE un arreglo: se envuelve a mano.
$json = @($resultado) | ConvertTo-Json -Depth 4 -Compress
if ([string]::IsNullOrWhiteSpace($json)) { $json = '[]' }
if (-not $json.StartsWith('[')) { $json = '[' + $json + ']' }
[System.IO.File]::WriteAllText($Salida, $json, (New-Object System.Text.UTF8Encoding($false)))
