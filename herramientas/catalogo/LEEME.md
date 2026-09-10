# Llenar el catálogo de placas (`backend/collector/placas.json`)

Estos scripts sacan de las páginas y los manuales **oficiales** de cada
fabricante los conectores **SATA** y las ranuras **M.2** y **PCIe** de cada
placa del catálogo, y los escriben en `placas.json`.

El catálogo **manda sobre el firmware** (ver `backend/collector/ranuras.go`), así
que un dato equivocado aquí se ve en pantalla como si fuera verdad: por eso solo
se usan fuentes oficiales y todo lo dudoso se descarta en vez de publicarse.

## Uso

```sh
cd herramientas/catalogo
python3 extraer.py Gigabyte giga_raw.json   # baja y recorta las páginas
python3 msi.py                              # ídem MSI      → msi_raw.json
python3 asus.py                             # ídem ASUS     → asus_raw.json
python3 asrock.py                           # manuales PDF  → asrock_spec.json
python3 specs.py                            # raws → specs.json (ya estructurado)
python3 merge.py                            # specs.json → placas.json
cd ../../backend/collector && go test ./    # el candado del catálogo
```

Las descargas se cachean en `cache/` y los PDF en `pdf/` (ninguna de las dos se
sube: están en `.gitignore`). Volver a correr todo es barato.

## Lo que hay que saber antes de tocarlos

- **Gigabyte**: las placas viejas llevan prefijo `GA-` y la revisión correcta
  (`rev-1x`, `rev-20`, `rev-51`…) hay que probarla a ciegas. El sitio responde
  **403** sin cabeceras de navegador.
- **MSI**: la sección de ranuras se llama `Slots`, no "Expansion Slots".
- **ASUS**: repite la cuenta de SATA (resumen + detalle por controladora);
  sumarla da el doble. Se usa el "Total supports N x SATA".
- **ASRock**: la web está tras Incapsula y bloquea todo, pero
  `download.asrock.com/Manual/<MODELO>.pdf` no. El manual repite las mismas
  ranuras una vez por familia de CPU: hay que deduplicar por etiqueta.
- **Biostar y ECS**: sin vía todavía (Cloudflare y SPA). Esas placas caen al
  firmware, que ya funciona.

Detalle completo y por qué de cada regla: memoria `proyecto-catalogo-placas`.
