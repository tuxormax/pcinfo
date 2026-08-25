@echo off
setlocal
chcp 65001 >nul
title Recopilador de pantallazos azules (BSOD)

REM ---------------------------------------------------------------------------
REM Lanzador de bluescreen.ps1
REM El .bat se auto-eleva a Administrador (TODO corre en la misma ventana).
REM Por defecto INSTALA la tarea que se dispara sola cuando ocurre un BSOD
REM (evento 1001) y ademas captura los pantallazos que ya hayan pasado.
REM El registro se acumula en C:\bluescreen.txt.
REM ---------------------------------------------------------------------------

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Se requieren permisos de Administrador. Relanzando elevado...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

set "PS1=%~dp0bluescreen.ps1"

if not exist "%PS1%" (
    echo No se encontro el script:
    echo   %PS1%
    echo El .bat y el .ps1 deben estar en la misma carpeta.
    echo.
    pause
    exit /b 1
)

REM Si se pasan argumentos, se reenvian tal cual al .ps1 y termina
if not "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
    echo.
    pause
    exit /b %errorlevel%
)

:menu
cls
echo ============================================================
echo    RECOPILADOR DE PANTALLAZOS AZULES (BSOD)
echo    Registro: C:\bluescreen.txt
echo ============================================================
echo.
echo   [1] INSTALAR: dejar el equipo capturando BSOD solo
echo       (crea la tarea que se dispara al ocurrir un pantallazo
echo        y de una vez recopila los que ya pasaron)
echo.
echo   [2] Recopilar AHORA los pantallazos nuevos (sin instalar)
echo   [3] Ver el registro C:\bluescreen.txt
echo   [4] Rehacer TODO el historial desde cero
echo   [5] Desinstalar la tarea (dejar de capturar solo)
echo   [0] Salir
echo.
set "OP="
set /p "OP=Elige una opcion (0-5): "

if "%OP%"=="1" goto instalar
if "%OP%"=="2" goto recopilar
if "%OP%"=="3" goto ver
if "%OP%"=="4" goto rehacer
if "%OP%"=="5" goto quitar
if "%OP%"=="0" goto salir
echo Opcion no valida.
timeout /t 2 >nul
goto menu

:instalar
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -InstalarTarea
goto volver

:recopilar
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
goto volver

:ver
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Ver
goto volver

:rehacer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Rehacer
goto volver

:quitar
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -QuitarTarea
goto volver

:volver
echo.
echo Presiona una tecla para volver al menu...
pause >nul
goto menu

:salir
endlocal
exit /b 0
