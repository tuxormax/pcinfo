# -*- coding: utf-8 -*-
"""Parsea las páginas oficiales (ya en caché) y produce las filas de catálogo:
sata (nº de conectores), m2[], pcie[] y notas."""
import html, json, re, sys
from fetch import get

def texto(h):
    t = re.sub(r'<script.*?</script>', ' ', h, flags=re.S)
    t = re.sub(r'<style.*?</style>', ' ', t, flags=re.S)
    t = re.sub(r'<br\s*/?>', '\n', t)
    t = re.sub(r'</(li|p|tr|div|td|h\d)>', '\n', t)
    t = re.sub(r'<[^>]+>', ' ', t)
    t = html.unescape(t).replace('™', '').replace('®', '')
    return [re.sub(r'[ \t\xa0]+', ' ', l).strip(' •\t') for l in t.split('\n') if l.strip(' •\t')]

def zona(lineas, inicios, fines):
    """Devuelve las líneas entre la primera cabecera de `inicios` y la de `fines`."""
    ini = None
    for n, l in enumerate(lineas):
        if any(l.strip().lower() == i.lower() for i in inicios):
            ini = n + 1
            break
    if ini is None:
        return []
    out = []
    for l in lineas[ini:ini + 60]:
        if any(l.strip().lower() == f.lower() for f in fines):
            break
        out.append(l)
    return out

PALABRAS = {'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8}

def num(s):
    s = s.strip().lower()
    return PALABRAS.get(s, None) if not s.isdigit() else int(s)

def cuenta_sata(lineas):
    total = 0
    for l in lineas:
        for m in re.finditer(r'(\d+|one|two|three|four|five|six|seven|eight)\s*x?\s*SATA[^,;\n]{0,14}?(?:ports?|connectors?)', l, re.I):
            n = num(m.group(1))
            if n:
                total += n
    return total

def limpia_tam(txt):
    tam = re.findall(r'\b(2230|2242|2260|2280|22110)\b', txt)
    return '/'.join(sorted(set(tam), key=int)) if tam else ''

# ---------------- Gigabyte ----------------
def gigabyte(lineas):
    exp = zona(lineas, ['Expansion Slots'], ['Multi-Graphics Technology', 'Storage Interface', 'Internal I/O Connectors', 'USB', 'Onboard Graphics'])
    sto = zona(lineas, ['Storage Interface'], ['USB', 'Internal I/O Connectors', 'Audio Codec', 'LAN', 'Back Panel Connectors', 'Expansion Slots'])
    pcie, gens = [], {}
    for l in exp:
        m = re.search(r'\(The ([^)]*?) (?:slots? )?conforms? to PCI Express ([\d.]+) standard', l, re.I)
        if m:
            for et in re.split(r'\s*(?:,|and)\s*', m.group(1)):
                et = et.strip().rstrip('slot').strip()
                if et:
                    gens[et.upper()] = m.group(2)
    # Gigabyte repite las MISMAS ranuras una vez por familia de procesador
    # ("AMD Ryzen 3000: PCIEX16 a x16 / PCIEX8 a x8" y otra vez para las APU).
    # Se deduplica por la etiqueta serigrafiada, quedándose con la primera (el
    # mejor caso); sin esto una X570 AORUS PRO salía con SEIS ranuras x16.
    etiquetadas, sueltas = {}, {}
    for l in exp:
        m = re.match(r'(\d+)\s*x\s*PCI Express x(\d+) slot(?:s)?(?:, running at x(\d+))?(?:.*?\(([A-Za-z0-9_]+)\))?', l, re.I)
        if not m:
            continue
        n, fisico, electrico, etiqueta = int(m.group(1)), m.group(2), m.group(3), (m.group(4) or '')
        et = etiqueta if n == 1 else ''
        gen = gens.get(et.upper()) or gens.get(('PCI EXPRESS X%s' % fisico)) or ''
        spec = 'PCIe %s x%s' % (gen, fisico) if gen else 'PCIe x%s' % fisico
        if electrico and electrico != fisico:
            spec += ' (funciona a x%s)' % electrico
        if et:
            etiquetadas.setdefault(et, spec)
        else:
            if fisico not in sueltas or n > sueltas[fisico][0]:
                sueltas[fisico] = (n, spec)
    for et, spec in etiquetadas.items():
        pcie.append({'label': et, 'spec': spec})
    for fisico, (n, spec) in sorted(sueltas.items(), key=lambda x: -int(x[0])):
        for _ in range(n):
            pcie.append({'label': 'PCIe_%d' % (len(pcie) + 1), 'spec': spec})
    # Igual que con las PCIe: Gigabyte repite el MISMO conector M.2 una vez por
    # familia de procesador, bajo una cabecera que trae su nombre
    # ("Integrated in the CPU (M2A_SOCKET):"). Se agrupa por ese nombre; sin
    # esto una X570 AORUS PRO salía con tres M.2 teniendo dos.
    m2, socket = {}, ''
    for l in sto:
        cab = re.match(r'.*\((M2[A-Z0-9_]*)\)\s*:\s*$', l, re.I)
        if cab:
            socket = cab.group(1).upper()
            continue
        m = re.match(r'(\d+)\s*x\s*M\.2 connector[s]?\s*\(?([^)]*)\)?', l, re.I)
        if not m:
            continue
        n, det = int(m.group(1)), m.group(2)
        # Gigabyte pone la serigrafía dentro del paréntesis en las placas
        # nuevas: "1 x M.2 connector (M2A_CPU), integrated in the CPU…".
        et_linea = re.match(r'\s*(M2[A-Z0-9_]*)\s*$', det.split(',')[0].strip(), re.I)
        if et_linea:
            socket = et_linea.group(1).upper()
            det = l  # el detalle está en el resto de la línea
        partes = []
        k = re.search(r'([A-Z]) key', det, re.I)
        if k:
            partes.append('llave ' + k.group(1).upper())
        p = re.search(r'PCIe\s*(?:Gen\s*)?([\d.]+)?(?:/[\d.]+)?\s*x(\d+)(?:/x\d+)?', det, re.I)
        if p:
            partes.append(('PCIe %s x%s' % (p.group(1), p.group(2))) if p.group(1) else 'PCIe x%s' % p.group(2))
        if re.search(r'SATA', det, re.I):
            partes.append('SATA')
        t = limpia_tam(det)
        if t:
            partes.append(t)
        spec = ', '.join(partes) or 'M.2'
        for i in range(n):
            clave = socket or 'M2_%d' % (len(m2) + 1)
            if n > 1:
                clave = '%s_%d' % (clave, i + 1)
            m2.setdefault(clave, spec)
    # La etiqueta se deja como la serigrafía de la placa (M2A_SOCKET), que es
    # lo que el técnico ve al abrir el equipo.
    m2 = [{'label': k, 'spec': v} for k, v in m2.items()]
    for i, r in enumerate(m2, 1):
        if not re.search(r'\d', r['label']):
            r['label'] = 'M.2_%d' % i
    return cuenta_sata(sto), m2, pcie, notas(exp + sto)

# ---------------- MSI ----------------
def msi(lineas):
    exp = zona(lineas, ['Slots', 'Expansion Slots', 'Expansion Slot'], ['Onboard Graphics', 'Storage', 'Multi-GPU', 'USB', 'Audio', 'LAN', 'M.2 Slot'])
    sto = zona(lineas, ['Storage', 'On-Board SATA'], ['USB', 'Audio', 'LAN', 'Slots', 'Multi-GPU', 'RAID', 'Internal I/O'])
    if not sto:
        sto = lineas
    pcie = []
    for l in exp:
        m = re.match(r'(\d+)\s*x\s*PCIe\s*([\d.]+(?:\s*/\s*[\d.]+)*)?\s*x(\d+)\s*slot', l, re.I)
        if not m:
            continue
        gen = (m.group(2) or '').split('/')[0].strip()
        ancho = m.group(3)
        et = re.search(r'\((PCI_?E\d+[^)]*)\)', l)
        modo = re.search(r'supports?\s*x(\d+)\s*(?:speed|mode)', l, re.I)
        for i in range(int(m.group(1))):
            spec = 'PCIe %s x%s' % (gen, ancho) if gen else 'PCIe x%s' % ancho
            if modo and modo.group(1) != ancho:
                spec += ' (funciona a x%s)' % modo.group(1)
            etiqueta = et.group(1).split(',')[0] if (et and int(m.group(1)) == 1) else 'PCIe_%d' % (len(pcie) + 1)
            pcie.append({'label': etiqueta, 'spec': spec})
    m2 = []
    for n, l in enumerate(sto):
        m = re.match(r'(\d+)\s*x\s*M\.2 slot[s]?\s*\(?([^)]*)\)?', l, re.I)
        if not m:
            continue
        det = ' '.join(sto[n:n + 4])
        partes = []
        k = re.search(r'Key\s*([A-Z](?:[+-][A-Z])?)', m.group(2), re.I)
        if k:
            partes.append('llave ' + k.group(1).upper())
        p = re.search(r'PCIe\s*([\d.]+)\s*x(\d+)', det, re.I)
        if p:
            partes.append('PCIe %s x%s' % (p.group(1), p.group(2)))
        if re.search(r'SATA', det, re.I):
            partes.append('SATA')
        t = limpia_tam(det)
        if t:
            partes.append(t)
        for i in range(int(m.group(1))):
            m2.append({'label': 'M.2_%d' % (len(m2) + 1), 'spec': ', '.join(partes) or 'M.2'})
    return cuenta_sata(sto), m2, pcie, notas(exp + sto)

# ---------------- ASUS ----------------
def sata_asus(sto):
    """ASUS repite la cuenta de SATA: primero el resumen ("Total supports 6 x
    SATA 6Gb/s ports") y luego el detalle por controladora. Sumarlo todo daba
    12 puertos en una placa con 6."""
    t = ' '.join(sto)
    m = re.search(r'Total\s+supports?\s+(\d+)\s*x\s*SATA', t, re.I)
    if m:
        return int(m.group(1))
    mejor = 0
    for l in sto:
        for m in re.finditer(r'(\d+)\s*x\s*SATA\s*6Gb/s\s*ports?', l, re.I):
            mejor = max(mejor, int(m.group(1)))
    return mejor

def asus(lineas):
    exp = zona(lineas, ['Expansion Slots'], ['Storage', 'Ethernet', 'USB', 'Audio', 'Operating System', 'Form Factor', 'Internal I/O'])
    sto = zona(lineas, ['Storage'], ['USB', 'Ethernet', 'Audio', 'Operating System', 'Form Factor', 'Expansion Slots', 'Internal I/O'])
    pcie = []
    for l in exp:
        m = re.match(r'(\d+)\s*x\s*PCIe\s*([\d.]+)?\s*x(\d+)(?:\s*\(x(\d+)\))?', l, re.I)
        if not m:
            continue
        gen, ancho, modo = m.group(2), m.group(3), m.group(4)
        for i in range(int(m.group(1))):
            spec = 'PCIe %s x%s' % (gen, ancho) if gen else 'PCIe x%s' % ancho
            if modo and modo != ancho:
                spec += ' (funciona a x%s)' % modo
            pcie.append({'label': 'PCIe_%d' % (len(pcie) + 1), 'spec': spec})
    m2, texto_sto = [], ' '.join(sto)
    n_m2 = 0
    m = re.search(r'Total\s+supports?\s+(\d+)\s*x\s*M\.2', texto_sto, re.I) or \
        re.search(r'(\d+)\s*x\s*M\.2 slot', texto_sto, re.I)
    if m:
        n_m2 = int(m.group(1))
    etiquetadas = re.findall(r'M\.2_(\d+) slot\s*\(?([^)]*)\)?', texto_sto, re.I)
    if etiquetadas:
        vistas = set()
        for et, det in etiquetadas:
            if et in vistas:
                continue    # el texto de ASUS repite las etiquetas en las notas
            vistas.add(et)
            partes = []
            k = re.search(r'Key\s*([A-Z])', det, re.I)
            if k:
                partes.append('llave ' + k.group(1).upper())
            m2.append({'label': 'M.2_%s' % et, 'spec': ', '.join(partes) or 'M.2'})
    else:
        for i in range(n_m2):
            m2.append({'label': 'M.2_%d' % (i + 1), 'spec': 'M.2'})
    return sata_asus(sto), m2, pcie, notas(exp + sto)

def notas(lineas):
    out = []
    for l in lineas:
        if re.search(r'(unavailable|will be disabled|shares? bandwidth|not available when|cannot be used)', l, re.I):
            out.append(re.sub(r'\s+', ' ', l).strip())
    return ' '.join(out)[:300]

PARSERS = {'Gigabyte': gigabyte, 'MSI': msi, 'ASUS': asus}

def main():
    raws = {'Gigabyte': 'giga_raw.json', 'MSI': 'msi_raw.json', 'ASUS': 'asus_raw.json'}
    salida = {}
    for marca, f in raws.items():
        try:
            raw = json.load(open(f))
        except Exception:
            continue
        for modelo, d in raw.items():
            h = get(d['url'], pausa=0)
            if not h:
                continue
            sata, m2, pcie, nota = PARSERS[marca](texto(h))
            # Una lista de PCIe SIN ninguna ranura x16, o SOLO con x16, casi
            # siempre viene recortada: las páginas resumidas de fabricante
            # publican la x16 y se saltan las x1. Publicar "1 ranura PCIe" en una
            # placa que tiene tres es peor que no publicar nada: el catálogo
            # MANDA sobre el firmware, así que el error se vería como verdad.
            anchos = [r['spec'] for r in pcie]
            if not any('x16' in a for a in anchos) or all('x16' in a for a in anchos):
                pcie = []
            salida['%s|%s' % (marca, modelo)] = {
                'sata': sata, 'm2': m2, 'pcie': pcie, 'notas': nota, 'fuente': d['url']}
    json.dump(salida, open('specs.json', 'w'), indent=1, ensure_ascii=False)
    faltan = [k for k, v in salida.items() if not v['sata'] or (not v['pcie'])]
    print('placas parseadas:', len(salida), '| incompletas:', len(faltan))
    for k in faltan:
        print('  incompleta:', k, salida[k]['sata'], len(salida[k]['pcie']), len(salida[k]['m2']))

if __name__ == '__main__':
    main()
