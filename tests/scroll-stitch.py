#!/usr/bin/env python3
"""Stitch scrolling captures through the real CLI with a fake grim that crops a synthetic page at a known scroll
offset: text on white, repeated list rows, horizontal, scrolling back up, overshooting and sub-pixel shifts.
Results must equal the page pixel for pixel (sub-pixel: within 2 rows). No Wayland session needed."""
import json, os, pathlib, random, struct, subprocess, sys, tempfile, zlib
root = pathlib.Path(__file__).resolve().parents[1]; binary = root/'target/debug/omashot'
W, VH = 300, 200
def png_rows(path):  # decodes the 8-bit RGB/RGBA PNGs the backend writes, as RGB rows
    d = path.read_bytes(); i = 8; idat = b''
    while i < len(d):
        n, = struct.unpack('>I', d[i:i+4]); t, body = d[i+4:i+8], d[i+8:i+8+n]; i += 12+n
        if t == b'IHDR': w, h, _, ct = struct.unpack('>IIBB', body[:10])
        elif t == b'IDAT': idat += body
    bpp = {2: 3, 6: 4}[ct]; raw = zlib.decompress(idat); stride = w*bpp; prev = bytearray(stride); rows = []
    for y in range(h):
        f = raw[y*(stride+1)]; line = bytearray(raw[y*(stride+1)+1:(y+1)*(stride+1)])
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = [0, a, b, (a+b)//2, a if abs(b-c) <= abs(a-c) and abs(b-c) <= abs(a+b-2*c) else b if abs(a-c) <= abs(a+b-2*c) else c][f]
            line[x] = (line[x]+p) & 255
        rows.append(bytes(v for x, v in enumerate(line) if bpp == 3 or x % 4 < 3)); prev = line
    return rows
def page(kind, w, h, seed):
    rng = random.Random(seed); img = [bytearray(b'\xff'*3*w) for _ in range(h)]
    def rect(x0, y0, x1, y1, c):
        for y in range(max(0, y0), min(h, y1)): img[y][3*x0:3*x1] = bytes(c)*(x1-x0)
    y = 10
    while y < h-40:
        if kind == 'list':  # identical row chrome, varying text
            rect(10, y, w-10, y+1, (220, 220, 220)); rect(16, y+8, 40, y+32, (90, 140, 220)); x0, y0, lh = 50, y+14, 44
        else: x0, y0, lh = 12, y, 22
        x, end = x0, rng.randint(w//3, w-12)
        while x < end:
            for gx in range(x, min(x+rng.randint(15, 60), end), 7):
                g = rng.randint(7, 13); rect(gx, y0+14-g, gx+rng.randint(2, 5), y0+14, (25, 25, 25))
            x += 70
        y += lh+(22 if kind == 'doc' and rng.random() < .15 else 0)
    return [bytes(r) for r in img]
fails = []
def run(name, kind, offsets, axis='vertical', errors=(), exact=True):
    with tempfile.TemporaryDirectory(prefix='omashot-stitch-test-') as td:
        td = pathlib.Path(td); (td/'bin').mkdir(); n = int(max(offsets))+W+VH+60
        full = page(kind, W if axis == 'vertical' else VH, n, 7)
        if axis == 'horizontal': full = [b''.join(full[y][3*x:3*x+3] for y in range(n)) for x in range(VH)]
        pw = len(full[0])//3; (td/'page.raw').write_bytes(b''.join(full))
        env = dict(os.environ, XDG_DATA_HOME=str(td/'data'), XDG_CONFIG_HOME=str(td/'config'), PATH=f"{td/'bin'}:{os.environ['PATH']}")
        (td/'bin/grim').write_text(f'''#!/usr/bin/env python3
import math, pathlib, struct, sys, zlib
a = sys.argv[1:]; (gx, gy), (gw, gh) = [map(int, s.replace('x', ',').split(',')) for s in a[a.index('-g')+1].split(' ')]
o = float(pathlib.Path({str(td/'offset')!r}).read_text()); i, f = math.floor(o), o-math.floor(o); d = pathlib.Path({str(td/'page.raw')!r}).read_bytes()
px = lambda x, y: d[3*({pw}*y+x):3*({pw}*y+x)+3]
def at(x, y):
    p, q = (px(x, y+i), px(x, y+i+1)) if {axis == 'vertical'} else (px(x+i, y), px(x+i+1, y))
    return bytes(round(p[k]*(1-f)+q[k]*f) for k in range(3))
rows = [b''.join(at(gx+x, gy+y) for x in range(gw)) for y in range(gh)]
chunk = lambda t, d: struct.pack('>I', len(d))+t+d+struct.pack('>I', zlib.crc32(t+d))
pathlib.Path(a[-1]).write_bytes(b'\\x89PNG\\r\\n\\x1a\\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', gw, gh, 8, 2, 0, 0, 0))
    +chunk(b'IDAT', zlib.compress(b''.join(b'\\0'+r for r in rows), 1))+chunk(b'IEND', b''))
''')
        os.chmod(td/'bin/grim', 0o755)
        cli = lambda *a: json.loads(subprocess.run([str(binary), 'scroll', *a], env=env, capture_output=True, text=True).stdout)
        (td/'offset').write_text(str(offsets[0]))
        geo = f'10,0 {W-20}x{VH}' if axis == 'vertical' else f'0,10 {W}x{VH-20}'
        sid = cli('start', '--geometry', geo, *(['--horizontal'] if axis == 'horizontal' else []))['session']; got = []
        for o in offsets[1:]:
            (td/'offset').write_text(str(o)); r = cli('append', sid)
            if 'error' in r: got.append((o, r['error'].split('.')[0]))
        result = cli('finish', sid); rows = png_rows(pathlib.Path(result['path']))
        left = [p.name for p in (td/'data/omashot').glob('.scroll*')]
        accepted = [o for o in offsets if o not in [e[0] for e in got]]; lo, hi = int(min(accepted)), round(max(accepted))
        want = [r[30:3*(W-10)] for r in full[lo:hi+VH]] if axis == 'vertical' else [r[3*lo:3*(hi+W)] for r in full[10:VH-10]]
        ok = (rows == want if exact else abs(len(rows)-len(want)) <= 2) and got == list(errors) and not left
        print(('PASS ' if ok else 'FAIL ')+name+('' if ok else f': {len(rows)} rows, want {len(want)}; errors {got}, want {list(errors)}; left {left}'))
        if not ok: fails.append(name)
if __name__ == '__main__':
    up, far = 'Scrolled back up', 'No matching overlap found'
    run('text page, wheel steps and pauses', 'doc', [0, 37, 120, 120, 250, 300, 420, 540, 660])
    run('text page, scroll back up then down', 'doc', [0, 100, 160, 110, 60, 160, 300], errors=[(110, up), (60, up)])
    run('text page, overshoot then recover', 'doc', [0, 100, 420, 250, 380], errors=[(420, far)])
    run('repeated list rows, back up then down', 'list', [0, 90, 180, 136, 92, 180, 290], errors=[(136, up), (92, up)])
    run('horizontal text', 'doc', [0, 80, 160, 160, 260], axis='horizontal')
    run('sub-pixel scrolling', 'doc', [0, 30.5, 90.25, 150.75, 240.5, 330.25], exact=False)
    sys.exit(f'{len(fails)} scenario(s) failed: {fails}' if fails else 0)
