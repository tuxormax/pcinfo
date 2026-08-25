# Comprueba que la herramienta bluescreen que se empaqueta esta sana y, sobre
# todo, que su analizador del volcado NO se ha separado del de PCInfo.
#
# POR QUE: el mismo codigo que lee el .dmp y senala al driver culpable vive en
# DOS archivos (herramientas\bluescreen\bluescreen.ps1 y
# backend\collector\errores_windows.ps1). Si uno se corrige y el otro no, el
# C:\bluescreen.txt y la pestana Historial de Errores acusan a drivers distintos
# del mismo pantallazo, que es peor que no decir nada.
#
# Se corre solo en el workflow del instalador; a mano:  pwsh construir\verificar_bluescreen.ps1

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$bs   = Join-Path $raiz 'herramientas\bluescreen\bluescreen.ps1'
$bat  = Join-Path $raiz 'herramientas\bluescreen\bluescreen.bat'
$pci  = Join-Path $raiz 'backend\collector\errores_windows.ps1'

foreach ($f in @($bs, $bat, $pci)) {
    if (-not (Test-Path $f)) { throw "Falta $f" }
}

# 1) ASCII puro. PowerShell 5.1 lee un .ps1 sin BOM como ANSI: un acento suelto
#    sale como basura en el informe del cliente.
$bytes = [System.IO.File]::ReadAllBytes($bs)
$malos = @($bytes | Where-Object { $_ -gt 127 })
if ($malos.Count -gt 0) { throw "bluescreen.ps1 tiene $($malos.Count) bytes fuera de ASCII; debe ser ASCII puro" }
Write-Host "OK: bluescreen.ps1 es ASCII puro"

# 2) Sintaxis valida de los dos.
foreach ($f in @($bs, $pci)) {
    $errs = $null; $toks = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$toks, [ref]$errs)
    if ($errs.Count -gt 0) { throw "$f no compila: $($errs[0].Message) (linea $($errs[0].Extent.StartLineNumber))" }
}
Write-Host "OK: los dos .ps1 compilan"

# 3) El analizador es el MISMO en los dos. Se compara sin comentarios, sin
#    espacios y sin acentos (uno va en ASCII y el otro en UTF-8 con BOM).
function Nucleo([string]$ruta, [string]$hasta) {
    $lineas = Get-Content -LiteralPath $ruta
    $ini = ($lineas | Select-String -SimpleMatch 'function Lee-Bytes' | Select-Object -First 1).LineNumber
    $fin = ($lineas | Select-String -SimpleMatch $hasta            | Select-Object -First 1).LineNumber
    if (-not $ini -or -not $fin -or $fin -le $ini) { throw "No se pudo acotar el analizador en $ruta" }
    $trozo = $lineas[($ini-1)..($fin-2)] | Where-Object { $_ -notmatch '^\s*#' }
    $txt = ($trozo -join "`n")
    $txt = $txt -replace '\s+', ''
    # Fuera lo que no sea ASCII: en un archivo los comentarios llevan acentos y
    # en el otro no, y eso no es una divergencia de codigo.
    return (($txt.ToCharArray() | Where-Object { [int]$_ -lt 128 }) -join '')
}
$a = Nucleo $bs  'function Buscar-Dump'
$b = Nucleo $pci 'function Get-Minidumps'
if ($a -ne $b) {
    throw "El analizador del volcado NO coincide entre bluescreen.ps1 y errores_windows.ps1. " +
          "Copia el bloque (Lee-Bytes ... fin de Analiza-Dump) del que corregiste al otro."
}
Write-Host "OK: el analizador del volcado es identico en los dos archivos ($($a.Length) caracteres)"
Write-Host "bluescreen verificado"
