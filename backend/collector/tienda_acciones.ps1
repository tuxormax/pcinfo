# Parte final del script de la Tienda (acciones). Va DESPUES del fragmento por
# version (tienda_win10.ps1 / tienda_win11.ps1), que define Preparar-Instalacion.
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
        Preparar-Instalacion
        Start-InstalacionMultiple -Apps @($apps) -Arch $Arch -Ring $Ring -TodosLosUsuarios ([bool]::Parse($Todos))
    }
    'InstalarCarpeta' {
        Preparar-Instalacion
        Start-InstalacionLocal -Carpeta $Carpeta -Arch $Arch -TodosLosUsuarios ([bool]::Parse($Todos))
    }
    default { throw "Accion desconocida: $Accion" }
}
