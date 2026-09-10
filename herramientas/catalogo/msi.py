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

def trozo(t, ini, fines, largo=1500):
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

placas = json.load(open('/home/tuxor/www/pcinfo/backend/collector/placas.json'))
res = {}
for p in placas:
    if p['fabricante'] != 'MSI':
        continue
    m = p['modelo']
    for slug in [m.replace(' ', '-'), m.replace(' ', '-').replace('/', '-')]:
        url = f"https://www.msi.com/Motherboard/{slug}/Specification"
        h = get(url, pausa=0.6)
        if h and 'SATA' in h and len(h) > 30000:
            t = texto(h)
            res[m] = {
                'url': url,
                'expansion': trozo(t, 'Slots', ['Onboard Graphics', 'Storage', 'Multi-GPU', 'Internal I/O', 'USB', 'Audio', 'LAN']),
                'storage': trozo(t, 'Storage', ['USB', 'Internal I/O', 'Audio', 'LAN', 'Slots', 'Multi-GPU']),
            }
            print('OK', m, flush=True)
            break
    else:
        print('FALTA', m, flush=True)
json.dump(res, open('msi_raw.json', 'w'), indent=1, ensure_ascii=False)
print('total', len(res))
