# -*- coding: utf-8 -*-
"""Mezcla specs.json (puertos) dentro de placas.json conservando el formato de
una placa por línea. Las notas del fabricante se traducen por patrón; lo que no
case se deja fuera (mejor sin nota que media ficha en inglés)."""
import json, re, sys

RUTA = '/home/tuxor/www/pcinfo/backend/collector/placas.json'

def puertos_sata(txt):
    """'SATA5~6' / 'SATA_5/6' / 'SATA 5 and 6' → '5 y 6'."""
    n = re.findall(r'\d+', txt)
    if not n:
        return ''
    if len(n) == 1:
        return n[0]
    if '~' in txt or '-' in txt:
        a, b = int(n[0]), int(n[-1])
        n = [str(x) for x in range(a, b + 1)]
    return ', '.join(n[:-1]) + ' y ' + n[-1]

def traduce(nota):
    """Convierte las advertencias del fabricante en una frase en español. Solo
    los patrones reconocidos; el resto se descarta."""
    out = []
    for frase in re.split(r'(?<=\.)\s+', nota):
        f = frase.strip()
        if not f:
            continue
        # "When installing a device in M2_1, SATA5~6 will be unavailable"
        m = re.search(r'(M\.?2[_ ]?\d?).{0,80}?(SATA[_ ]?[\d~/,\- and]+).{0,40}?(unavailable|disabled|not available)', f, re.I)
        if m:
            out.append('Al usar la ranura %s se apagan los puertos SATA %s.'
                       % (m.group(1).upper().replace('M2', 'M.2_').replace('__', '_').rstrip('_'),
                          puertos_sata(m.group(2))))
            continue
        # "...PCI_E3 slot will be unavailable"
        m = re.search(r'(M\.?2[_ ]?\d?).{0,90}?(PCI_?E\d+).{0,40}?(unavailable|disabled|not available)', f, re.I)
        if m:
            out.append('Al usar la ranura %s queda inutilizable la ranura %s.'
                       % (m.group(1).upper(), m.group(2).upper()))
            continue
        # "The M.2 slot shares bandwidth with SATA6G_2" / "The PCIEX4 slot
        # shares bandwidth with the PCIEX1_3 slot": líneas compartidas. Es LA
        # advertencia más común y la que más caro sale ignorar.
        m = re.search(r'(?:The\s+)?([A-Za-z0-9_./]+(?:\s+[A-Za-z0-9_./]+)?)\s+(?:connector|slot|port)?s?\s*shares?\s+bandwidth\s+with\s+(?:the\s+)?([A-Za-z0-9_.]+(?:[/ ][A-Za-z0-9_.]+)?)\s*(?:connectors?|slots?|ports?)?', f, re.I)
        if m:
            uno, dos = m.group(1).strip(), m.group(2).strip()
            out.append('%s comparte líneas con %s: al ocupar uno, el otro baja de '
                       'velocidad o deja de funcionar.' % (uno, dos))
            continue
        m = re.search(r'([A-Za-z0-9_.]+)\s*(?:slot)?\s*will be (?:unavailable|disabled|suspended)[^.]*?(?:M\.?2[_ ]?\d?|installed in the ([A-Za-z0-9_.]+))', f, re.I)
        if m:
            otra = m.group(2) or 'la ranura M.2'
            out.append('%s queda inutilizable si se pone un SSD en %s.' % (m.group(1), otra))
            continue
        m = re.search(r'(SATA[\w]*\d)\s*(?:and|,|&)\s*(SATA[\w]*\d).{0,40}?(?:unavailable|disabled).{0,60}?M\.?2', f, re.I)
        if m:
            out.append('Los puertos %s y %s se apagan al poner un SSD en la ranura M.2.'
                       % (m.group(1).upper(), m.group(2).upper()))
            continue
        # "SATA5~6 will be unavailable when M2_1 is occupied"
        m = re.search(r'(SATA[_ ]?[\d~/,\- and]+).{0,60}?(unavailable|disabled).{0,60}?(M\.?2[_ ]?\d?)', f, re.I)
        if m:
            out.append('Los puertos SATA %s se apagan al ocupar la ranura %s.'
                       % (puertos_sata(m.group(1)), m.group(3).upper()))
            continue
    # Sin duplicados y en orden.
    vistas, limpio = set(), []
    for f in out:
        if f not in vistas:
            vistas.add(f)
            limpio.append(f)
    return ' '.join(limpio)[:400]


LLAVES = {'A', 'B', 'E', 'M'}
RE_SUJETO = re.compile(r'^(M\.?2[_A-Za-z0-9.]*|PCI_?E[_A-Za-z0-9.]*|PCIEX?[_A-Za-z0-9.]*|SATA[_A-Za-z0-9./~-]*)$', re.I)

def sujeto_valido(s):
    """Solo se publica una nota si el sujeto es un nombre de ranura/puerto
    reconocible. Las frases del fabricante llegan partidas por el PDF y a veces
    el sujeto acaba siendo 'use' o 'the other one': una nota así no informa y
    encima da la impresión de dato roto."""
    return bool(RE_SUJETO.match(s.strip()))

def sanea_nota(n):
    n = re.sub(r'\s+', ' ', n).strip()
    n = re.sub(r'\b(slot|connector|port)s?\b', lambda m: {'slot': 'ranura', 'connector': 'conector', 'port': 'puerto'}[m.group(1).lower()], n, flags=re.I)
    n = re.sub(r'^([A-Z][A-Za-z0-9_.]*) ranura ', r'la ranura \1 ', n)
    n = re.sub(r'^([A-Z][A-Za-z0-9_.]*) conector ', r'el conector \1 ', n)
    n = re.sub(r'con ([A-Z][A-Za-z0-9_.]*) (ranura|conector|puerto)', r'con \2 \1', n)
    n = n.replace('con ranura ', 'con la ranura ').replace('con conector ', 'con el conector ')
    n = n.replace('con puerto ', 'con el puerto ')
    n = n[0].upper() + n[1:] if n else n
    n = n.replace('.:', ':').replace(' .', '.').replace('..', '.')
    # Sin números de puerto la frase no dice nada ("se apagan los puertos SATA .")
    if re.search(r'SATA\s*\.', n) or re.search(r'puertos SATA\s*(?:y|\.)', n):
        return ''
    return n

def sanea_ranuras(rs):
    """Quita las llaves inventadas: solo A, B, E y M existen en M.2. Una 'llave
    T' salida de un mal recorte del PDF haría dudar de todo el catálogo."""
    for r in rs:
        m = re.match(r'llave ([A-Z])(.*)$', r.get('spec', ''))
        if m and m.group(1) not in LLAVES:
            r['spec'] = m.group(2).lstrip(', ').strip() or 'M.2'
    return rs

def main():
    placas = json.load(open(RUTA))
    specs = json.load(open('specs.json'))
    sin_traducir = []
    tocadas = 0
    for p in placas:
        k = '%s|%s' % (p['fabricante'], p['modelo'])
        s = specs.get(k)
        if not s:
            continue
        nuevo = {}
        if s['sata']:
            nuevo['sata'] = s['sata']
        if s['m2']:
            nuevo['m2'] = sanea_ranuras(s['m2'])
        if s['pcie']:
            nuevo['pcie'] = s['pcie']
        if not nuevo:
            continue
        if s['notas']:
            es = traduce(s['notas'])
            # El filtro va ANTES de castellanizar los nombres: después la frase
            # ya empieza por "La ranura…" y el sujeto real queda en medio.
            if es and (sujeto_valido(es.split(' ')[0]) or es.startswith(('Al usar', 'Los puertos'))):
                es = sanea_nota(es)
            else:
                es = ''
            if es:
                nuevo['notas'] = es
            else:
                sin_traducir.append((k, s['notas']))
        # Orden de claves estable: los datos de RAM primero, luego expansión.
        for campo in ['sata', 'm2', 'pcie', 'notas']:
            if campo in nuevo:
                p[campo] = nuevo[campo]
        if s['fuente'] != p.get('fuente'):
            p['fuentePuertos'] = s['fuente']
        tocadas += 1

    orden = ['fabricante', 'modelo', 'ranuras', 'maxGiB', 'sata', 'm2', 'pcie', 'notas', 'fuente', 'fuentePuertos']
    lineas = []
    for p in placas:
        d = {k: p[k] for k in orden if k in p}
        for k in p:
            if k not in d:
                d[k] = p[k]
        lineas.append('  ' + json.dumps(d, ensure_ascii=False, separators=(',', ':')))
    open(RUTA, 'w', encoding='utf8').write('[\n' + ',\n'.join(lineas) + '\n]\n')
    print('placas con puertos:', tocadas, 'de', len(placas))
    print('notas sin traducir:', len(sin_traducir))
    for k, n in sin_traducir[:12]:
        print('  ', k, '->', n[:120])

if __name__ == '__main__':
    main()
