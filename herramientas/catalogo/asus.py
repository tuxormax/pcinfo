import html, json, re
from fetch import get

def texto(h):
    t = re.sub(r'<script.*?</script>', ' ', h, flags=re.S)
    t = re.sub(r'<style.*?</style>', ' ', t, flags=re.S)
    t = re.sub(r'<br\s*/?>', '\n', t)
    t = re.sub(r'</(li|p|tr|div|td)>', '\n', t)
    t = re.sub(r'<[^>]+>', ' ', t)
    t = html.unescape(t)
    return '\n'.join(re.sub(r'[ \t\xa0]+', ' ', l).strip() for l in t.split('\n') if l.strip())

def trozo(t, ini, fines, largo=1200):
    i = t.find('\n' + ini + '\n')
    if i < 0:
        return ''
    i += 1
    j = len(t)
    for f in fines:
        k = t.find('\n' + f + '\n', i + len(ini))
        if 0 < k < j:
            j = k
    return t[i:min(j, i + largo)]

SERIES = ['prime', 'tuf-gaming', 'rog-strix', 'csm', 'all-series', 'proart', 'pro',
          'rog-maximus', 'rog-crosshair', 'expedition']

def slug(m):
    s = m.lower().replace('/', '-').replace('.', '')
    s = re.sub(r'[^a-z0-9]+', '-', s).strip('-')
    return s

placas = json.load(open('/home/tuxor/www/pcinfo/backend/collector/placas.json'))
res = {}
for p in placas:
    if p['fabricante'] != 'ASUS':
        continue
    m = p['modelo']
    sl = slug(m)
    hallado = False
    for serie in SERIES:
        for pref in ['', 'us/']:
            url = f"https://www.asus.com/{pref}motherboards-components/motherboards/{serie}/{sl}/techspec/"
            h = get(url, pausa=0.5)
            if h and 'SATA' in h and len(h) > 150000:
                t = texto(h)
                res[m] = {
                    'url': url,
                    'expansion': trozo(t, 'Expansion Slots', ['Storage', 'Ethernet', 'USB', 'Audio', 'Operating System', 'Form Factor']),
                    'storage': trozo(t, 'Storage', ['USB', 'Ethernet', 'Audio', 'Operating System', 'Form Factor', 'Expansion Slots']),
                }
                print('OK', m, serie, flush=True)
                hallado = True
                break
        if hallado:
            break
    if not hallado:
        print('FALTA', m, flush=True)
json.dump(res, open('asus_raw.json', 'w'), indent=1, ensure_ascii=False)
print('total', len(res))
