#!/usr/bin/env python3
"""Añade (o reemplaza) una fila de backend/collector/catalogo_drivers.json.

Descarga el archivo, calcula su SHA-256 y escribe la fila: el hash NUNCA se
teclea a mano. Uso:

  python3 -I herramientas/agrega_driver_web.py --id hp-realtek-lan \
     --nombre "Realtek Ethernet" --fabricante HP --tipo exe --args "-s" \
     --buscarid 'VEN_10EC&DEV_(8168|8136)' --equipo 'HP .*805 G9' \
     --version 1166.022.1119.2024 --url https://ftp.hp.com/.../sp157347.exe
"""
import argparse, hashlib, json, os, sys, tempfile, urllib.request

RUTA = os.path.join(os.path.dirname(__file__), "..", "backend", "collector", "catalogo_drivers.json")

a = argparse.ArgumentParser()
a.add_argument("--id", required=True)
a.add_argument("--nombre", required=True)
a.add_argument("--fabricante", required=True)
a.add_argument("--buscarid", default="")
a.add_argument("--ejecuta", default="")
a.add_argument("--ejecuta-args", default="")
a.add_argument("--exitos", default="", help="códigos de salida buenos, ej. 0,3010,256")
a.add_argument("--url", required=True)
a.add_argument("--tipo", required=True, choices=["zip", "exe", "msi"])
a.add_argument("--args", default="")
a.add_argument("--equipo", default="")
a.add_argument("--version", default="")
a.add_argument("--nota", default="")
o = a.parse_args()

if not o.url.lower().startswith("https://"):
    sys.exit("la URL debe ser https")
if not o.buscarid and not (o.ejecuta and o.equipo):
    sys.exit("hace falta --buscarid (controlador suelto) o --ejecuta y --equipo (herramienta del fabricante)")
# Copia local en drivers/<fabricante>/ (fuera de git): el archivo queda a mano.
dest = os.path.join(os.path.dirname(__file__), "..", "drivers", o.fabricante.strip())
os.makedirs(dest, exist_ok=True)
ruta = os.path.join(dest, os.path.basename(o.url.split("?")[0]))
h = hashlib.sha256()
req = urllib.request.Request(o.url, headers={"User-Agent": "PCInfo"})
with urllib.request.urlopen(req, timeout=60) as r, open(ruta, "wb") as out:
    while True:
        b = r.read(1 << 20)
        if not b:
            break
        h.update(b)
        out.write(b)
print("guardado en", os.path.normpath(ruta))
fila = {"id": o.id, "nombre": o.nombre, "fabricante": o.fabricante, "buscarId": o.buscarid,
        "equipo": o.equipo, "url": o.url, "sha256": h.hexdigest(), "tipo": o.tipo,
        "args": o.args, "version": o.version, "nota": o.nota}
if o.ejecuta:
    fila.update({"ejecuta": o.ejecuta, "ejecutaArgs": o.ejecuta_args})
if o.exitos:
    fila["exitos"] = [int(x) for x in o.exitos.split(",")]
datos = json.load(open(RUTA, encoding="utf-8"))
datos = [d for d in datos if d["id"] != o.id] + [fila]
with open(RUTA, "w", encoding="utf-8") as f:
    json.dump(datos, f, ensure_ascii=False, indent=1)
    f.write("\n")
print("OK", o.id, h.hexdigest())
