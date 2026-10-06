# Quita UNA app de la Tienda (Appx/MSIX) del usuario actual.
# Lo llama backend/collector/software_windows.go (quitaAppx). Si falla, escribe
# el motivo en la salida estandar y termina con codigo 1.
param(
    [Parameter(Mandatory = $true)][string]$Paquete
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    $app = Get-AppxPackage | Where-Object { $_.PackageFullName -eq $Paquete } | Select-Object -First 1
    if (-not $app) { Write-Output 'La app ya no esta instalada para este usuario.'; exit 1 }
    if ($app.IsFramework -or $app.NonRemovable -or $app.SignatureKind -eq 'System') {
        Write-Output 'Esta app es parte de Windows y no se puede quitar desde PCInfo.'
        exit 1
    }
    Remove-AppxPackage -Package $app.PackageFullName
} catch {
    Write-Output ('No se pudo quitar la app: ' + $_.Exception.Message)
    exit 1
}
