"""Extrae el texto de las secciones de expansión/almacenamiento de las páginas
de especificaciones de los fabricantes."""
import html, json, re, sys
from fetch import get

def texto(h):
    t = re.sub(r'<script.*?</script>', ' ', h, flags=re.S)
    t = re.sub(r'<style.*?</style>', ' ', t, flags=re.S)
    t = re.sub(r'<br\s*/?>', '\n', t)
    t = re.sub(r'</(li|p|tr|div|td)>', '\n', t)
    t = re.sub(r'<[^>]+>', ' ', t)
    t = html.unescape(t)
    lineas = [re.sub(r'[ \t\xa0]+', ' ', l).strip() for l in t.split('\n')]
    return '\n'.join(l for l in lineas if l)

def trozo(t, ini, fines, largo=1800):
    i = t.find(ini)
    if i < 0:
        return ''
    j = len(t)
    for f in fines:
        k = t.find(f, i + len(ini))
        if 0 < k < j:
            j = k
    return t[i:min(j, i + largo)]

FINES = ['Multi-Graphics', 'Internal I/O', 'Back Panel', 'Onboard LAN', 'Audio',
         'USB', 'LAN', 'Form Factor', 'Operating System', 'Accessories', 'Storage Interface']

def secciones_gigabyte(t):
    return {
        'expansion': trozo(t, 'Expansion Slots', FINES),
        'storage': trozo(t, 'Storage Interface', ['USB', 'Internal I/O', 'Audio', 'LAN', 'Form Factor']),
    }

def slugs_gigabyte(modelo):
    s = modelo.replace(' ', '-').replace('/', '-')
    orden = ['GA-' + s, s] if re.match(r'^(A320|H61|H81|B75|Z77|B85|H97|Z97|78|97|99|F2A|G41)', s) else [s, 'GA-' + s]
    out = []
    for b in orden:
        for rev in ['rev-1x', 'rev-10', 'rev-20', 'rev-2x', 'rev-3x', 'rev-11', 'rev-12',
                    'rev-13', 'rev-14', 'rev-15', 'rev-40', 'rev-42', 'rev-50', 'rev-51',
                    'rev-60', 'rev-61', 'rev-1001', '']:
            out.append(f"{b}-{rev}" if rev else b)
    return out

def main():
    placas = json.load(open('/home/tuxor/www/pcinfo/backend/collector/placas.json'))
    marca = sys.argv[1]
    salida = sys.argv[2]
    res = {}
    for p in placas:
        if p['fabricante'] != marca:
            continue
        m = p['modelo']
        url_ok, t = None, ''
        for s in slugs_gigabyte(m):
            h = get(f"https://www.gigabyte.com/Motherboard/{s}/sp", pausa=0.5)
            if h and 'Expansion Slots' in h:
                url_ok, t = f"https://www.gigabyte.com/Motherboard/{s}/sp", texto(h)
                break
        if not url_ok:
            print('FALTA', m, flush=True)
            continue
        res[m] = {'url': url_ok, **secciones_gigabyte(t)}
        print('OK', m, flush=True)
    json.dump(res, open(salida, 'w'), indent=1, ensure_ascii=False)
    print('total', len(res))

if __name__ == "__main__":
    main()
