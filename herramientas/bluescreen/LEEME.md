# bluescreen — recopilador de pantallazos azules

Herramienta que PCInfo instala en Windows junto con la aplicación. Deja el equipo
**capturando solo** cada pantallazo azul y acumulándolos en `C:\bluescreen.txt`.

## Qué hace al instalarse

El instalador de PCInfo ejecuta `bluescreen.ps1 -InstalarTarea`, que:

1. Registra la tarea **`RecopilarBluescreens`**, disparada por el **evento 1001**
   (el que Windows escribe al reiniciar tras un pantallazo) y, de respaldo, al
   arrancar. Corre como SYSTEM. Es lo que hace de "servicio".
2. **Garantiza que Windows llegue a crear el volcado**: pone
   `CrashDumpEnabled = 3` (volcado pequeño), `MinidumpsCount = 50` y deja el
   archivo de paginación administrado por el sistema. Sin esto no hay `.dmp` que
   analizar — y sin `.dmp`, ni esta herramienta ni la pestaña *Historial de
   Errores* de PCInfo pueden decir qué driver causó el fallo.
3. Recopila los pantallazos que ya hubieran ocurrido.

Al desinstalar PCInfo se ejecuta `-QuitarTarea`. `C:\bluescreen.txt` **no se
borra**: es el informe del usuario.

## Aquí vive el original (desde 29-ago-2026)

Esta carpeta es **la única copia** de `bluescreen`. Antes había otra en
`tuxormax/windows` (`www/windows/bluescreen/`) y había que mantener las dos
idénticas byte a byte; **esa se eliminó**. PCInfo y bluescreen son herramientas
complementarias — una captura el pantallazo en cuanto ocurre, la otra lo explica
en la app — y comparten analizador, así que viven juntas.

Si buscas bluescreen en el repo `windows`, ya no está: está aquí.

## ⚠️ Y el analizador vive en DOS archivos

La parte que lee el `.dmp` y señala al driver culpable (`Lee-Triage`,
`Analiza-Dump` y sus ayudantes) es **el mismo código** que
`backend/collector/errores_windows.ps1`, para que el `.txt` y la aplicación no
puedan señalar a dos culpables distintos. Si se corrige el análisis, se corrige
en los dos.

Ojo con la codificación al copiar entre ellos:

- `bluescreen.ps1` es **ASCII puro** (PowerShell 5.1 lee un `.ps1` sin BOM como
  ANSI y rompe los acentos).
- `errores_windows.ps1` va en **UTF-8 con BOM** y sí lleva acentos.
