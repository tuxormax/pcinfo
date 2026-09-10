# -*- coding: utf-8 -*-
"""ASRock v2: manual oficial con -layout (la tabla de specs se lee entera) y
deduplicación por etiqueta de ranura. ASRock REPITE las mismas ranuras una vez
por familia de CPU ("Matisse", "Picasso", "Athlon"): contarlas todas daría 7
ranuras PCIe en una micro-ATX que tiene 3."""
import json, os, re, subprocess, urllib.parse

DIR = os.path.dirname(os.path.abspath(__file__))
PDF = os.path.join(DIR, 'pdf')
FILAS = ['Graphics', 'Audio', 'LAN', 'Storage', 'RAID', 'Connector', 'Rear Panel',
         'BIOS', 'Unique Feature', 'Support CD', 'Hardware Monitor', 'OS', 'Certifications',
         'Memory', 'Chipset', 'CPU', 'Slot', 'Form Factor', 'Wireless LAN']

def texto(modelo):
    f = os.path.join(PDF, re.sub(r'[^A-Za-z0-9_.+-]', '_', modelo) + '.pdf')
    if not os.path.exists(f) or os.path.getsize(f) < 100000:
        return ''
    return subprocess.run(["pdftotext", "-layout", "-f", "1", "-l", "25", f, "-"],
                          capture_output=True, text=True).stdout

def bloque(t, *etiquetas):
    """Texto de la(s) fila(s) de la tabla de especificaciones. Se concatenan
    TODAS las apariciones: en los manuales la fila se parte entre páginas y
    quedarse con la primera pierde justo la ranura x16, que va arriba."""
    trozos = []
    for etiqueta in etiquetas:
        for m in re.finditer(r'^(\s*)%s\s{2,}(.*)$' % re.escape(etiqueta), t, re.M):
            resto = t[m.start():]
            fin = len(resto)
            for f in FILAS:
                if f == etiqueta:
                    continue
                k = re.search(r'^\s*%s\s{2,}' % re.escape(f), resto[len(m.group(0)):], re.M)
                if k and k.start() + len(m.group(0)) < fin:
                    fin = k.start() + len(m.group(0))
            trozos.append(resto[:fin])
    return '\n'.join(trozos)

def parse(t):
    slot = bloque(t, 'Slot', 'Expansion Slot', 'Slots')
    sto = bloque(t, 'Storage')
    # --- PCIe, deduplicando por etiqueta (PCIE1/PCIE2) o por (gen, ancho).
    etiquetadas, sueltas = {}, {}
    RE_PCIE = re.compile(r'(\d+)\s*x\s*PCI\s*-?E(?:xpress)?\s*(?:Gen\s*)?([\d.]+)?\s*x\s*(\d+)\s*Slot[^\n]*', re.I)
    for m in RE_PCIE.finditer(slot):
        linea, gen, ancho = m.group(0), m.group(2), m.group(3)
        if gen and '.' not in gen:
            gen = gen + '.0'
        et = re.search(r'\((PCIE\d+)[^)]*\)', linea)
        modo = re.search(r'[:@]\s*x(\d+)\s*mode', linea, re.I)
        spec = 'PCIe %s x%s' % (gen, ancho) if gen else 'PCIe x%s' % ancho
        if modo and modo.group(1) != ancho:
            spec += ' (funciona a x%s)' % modo.group(1)
        if et:
            etiquetadas.setdefault(et.group(1), spec)   # la 1ª (mejor caso de CPU)
        else:
            # Sin etiqueta: ASRock repite la MISMA ranura una vez por familia de
            # CPU ("11th Gen…: 1 x PCIe 4.0 x16" / "10th Gen…: 1 x PCIe 3.0 x16").
            # Se agrupa por ANCHO y se guarda la primera (la mejor), no la suma.
            n = int(m.group(1))
            if ancho not in sueltas or n > sueltas[ancho][0]:
                sueltas[ancho] = (n, spec)
    pcie = [{'label': et, 'spec': s} for et, s in sorted(etiquetadas.items())]
    for ancho, (n, spec) in sorted(sueltas.items(), key=lambda x: -int(x[0])):
        for _ in range(n):
            pcie.append({'label': 'PCIe_%d' % (len(pcie) + 1), 'spec': spec})
    # --- SATA: el máximo declarado (se repite por variante, no se suma).
    sata = 0
    for m in re.finditer(r'(\d+)\s*x\s*SATA\s*([23])?\s*[\d.]* ?Gb/s\s*Connectors?', sto, re.I):
        sata = max(sata, int(m.group(1)))
    # --- M.2, deduplicando por etiqueta (M2_1, M2_2).
    m2 = {}
    for m in re.finditer(r'(\d+)\s*x\s*(?:Ultra\s*|Hyper\s*|Blazing\s*)?M\.2\s*Socket[^\n]*(?:\n[^\n]*){0,2}', sto + '\n' + slot, re.I):
        det = re.sub(r'\s+', ' ', m.group(0))
        et = re.search(r'\((M2_\d+)[^)]*\)', det)
        partes = []
        k = re.search(r'Key\s*([A-Z])', det, re.I)
        if k:
            partes.append('llave ' + k.group(1).upper())
        p = re.search(r'Gen\s*([\d])\s*x(\d+)', det, re.I)
        if p:
            partes.append('PCIe %s.0 x%s' % (p.group(1), p.group(2)))
        if re.search(r'SATA3', det, re.I):
            partes.append('SATA')
        tam = re.findall(r'\b(2230|2242|2260|2280|22110)\b', det)
        if tam:
            partes.append('/'.join(sorted(set(tam), key=int)))
        wifi = bool(re.search(r'Key\s*E|WiFi|Bluetooth|BT\b', det, re.I))
        if wifi:
            spec = 'llave E (módulo WiFi)'
        else:
            spec = ', '.join(partes) or 'M.2'
        if et:
            m2.setdefault(et.group(1), (spec, wifi))
        else:
            for _ in range(int(m.group(1))):
                m2.setdefault('M.2_%d' % (len(m2) + 1), (spec, wifi))
    m2 = [dict({'label': k.replace('M2_', 'M.2_'), 'spec': v[0]}, **({'wifi': True} if v[1] else {}))
          for k, v in sorted(m2.items())]
    anchos = [r['spec'] for r in pcie]
    if not any('x16' in a for a in anchos) or all('x16' in a for a in anchos):
        pcie = []   # lista recortada: ver el porqué en specs.py
    notas = []
    for l in (slot + sto).split('\n'):
        l = re.sub(r'\s+', ' ', l).strip(' •')
        if re.search(r'(will be disabled|unavailable|shares? bandwidth|cannot be used)', l, re.I):
            notas.append(l)
    return sata, m2, pcie, ' '.join(notas)[:300]

def main():
    placas = json.load(open('/home/tuxor/www/pcinfo/backend/collector/placas.json'))
    res = {}
    for p in placas:
        if p['fabricante'] != 'ASRock':
            continue
        t = texto(p['modelo'])
        if not t:
            print('SIN MANUAL', p['modelo'])
            continue
        sata, m2, pcie, notas = parse(t)
        if not sata and not pcie and not m2:
            print('SIN DATOS', p['modelo'])
            continue
        res['ASRock|' + p['modelo']] = {
            'sata': sata, 'm2': m2, 'pcie': pcie, 'notas': notas,
            'fuente': 'https://download.asrock.com/Manual/%s.pdf' % urllib.parse.quote(p['modelo'])}
        print('OK %-22s sata=%d m2=%d pcie=%d %s' % (p['modelo'], sata, len(m2), len(pcie),
              [x['spec'] for x in pcie]))
    json.dump(res, open('asrock_spec.json', 'w'), indent=1, ensure_ascii=False)
    print('total', len(res))

main()
