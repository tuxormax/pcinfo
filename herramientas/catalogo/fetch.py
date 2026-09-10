"""Descarga páginas de especificaciones con caché en disco."""
import hashlib, os, subprocess, time, sys

CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cache')
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"

def get(url, pausa=1.0):
    key = hashlib.sha1(url.encode()).hexdigest()
    f = os.path.join(CACHE, key)
    if os.path.exists(f):
        return open(f, encoding='utf8', errors='replace').read()
    cmd = ["curl", "-s", "--compressed", "-L", "--max-time", "30",
           "-A", UA,
           "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
           "-H", "Accept-Language: en-US,en;q=0.5",
           "-H", "Upgrade-Insecure-Requests: 1",
           "-H", "Sec-Fetch-Dest: document",
           "-H", "Sec-Fetch-Mode: navigate",
           "-H", "Sec-Fetch-Site: none",
           "-w", "\n@@HTTP@@%{http_code}", url]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    body, _, code = out.rpartition("\n@@HTTP@@")
    time.sleep(pausa)
    if code.strip() != "200":
        return ""
    open(f, 'w', encoding='utf8').write(body)
    return body
