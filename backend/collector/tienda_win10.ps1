# Fragmento SOLO Windows 10 (build < 22000). tienda_windows.go lo concatena entre
# tienda_windows.ps1 y tienda_acciones.ps1.
# --- Sideloading (falta en Windows 10 LTSC) ------------------------------
# LTSC no trae el paquete Microsoft.WindowsStore ni sus servicios de licencia
# (ClipSVC/LicenseManager). Add-AppxPackage los necesita para REGISTRAR
# cualquier paquete, aunque ya este descargado, y sin ellos falla con
# 0x80073CFF ("necesitas una licencia de desarrollador o un sistema con
# sideloading habilitado"). La solucion no es reinstalar la Store (contradice
# el proposito del modulo): es activar la directiva de sideloading, la misma
# via que usa TI para instalar apps LOB en equipos LTSC.
function Test-SideloadHabilitado {
    foreach ($r in @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    )) {
        try {
            $v = Get-ItemProperty -Path $r -Name 'AllowAllTrustedApps' -ErrorAction Stop
            if ($v.AllowAllTrustedApps -eq 1) { return $true }
        } catch { }
    }
    return $false
}

function Enable-Sideload {
    if (Test-SideloadHabilitado) { return }
    $ruta = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    try {
        New-Item -Path $ruta -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $ruta -Name 'AllowAllTrustedApps' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        Escribe 'AVISO' 'Se activo el sideloading de apps (falta por defecto en Windows 10 LTSC, que no trae la Tienda ni su servicio de licencias).'
    } catch {
        Escribe 'AVISO' ("No se pudo activar el sideloading automaticamente: {0}. Si la instalacion falla pidiendo 'un sistema con sideloading habilitado', activalo a mano en Configuracion > Privacidad y seguridad > Para desarrolladores." -f $_.Exception.Message)
    }
}

function Preparar-Instalacion { Enable-Sideload }
