#!/usr/bin/env python3
"""Rebuild OmaShot's original SVG mark, outlined wordmarks, and PNG icons.
Run: uv run --with fonttools python scripts/brand-assets.py
Requires rsvg-convert and NotoSans-Bold.ttf (override with OMASHOT_BRAND_FONT).
"""
from pathlib import Path
import os
import subprocess
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'plugin/assets/brand'
OUT.mkdir(parents=True, exist_ok=True)
INK, CORAL, AMBER = '#171b29', '#ff645e', '#ffbe63'
# An open O and a detached viewfinder corner. Original geometry; no vendor assets.
RING = 'M148 60H100C77.909 60 60 77.909 60 100V156C60 178.091 77.909 196 100 196H156C178.091 196 196 178.091 196 156V140'
CORNER = 'M184 60H196V100'

def mark(mono=None):
    return f'<g fill="none" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"><path stroke="{mono or CORAL}" d="{RING}"/><path stroke="{mono or AMBER}" d="{CORNER}"/></g>'

def svg(body, view='0 0 256 256', title='OmaShot'):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}" role="img"><title>{title}</title>{body}</svg>\n'

(OUT / 'omashot-mark.svg').write_text(svg(mark()))
(OUT / 'omashot-mark-mono.svg').write_text(svg(mark(INK)))
(OUT / 'omashot-mark-white.svg').write_text(svg(mark('#ffffff')))
app = svg(f'<rect x="8" y="8" width="240" height="240" rx="58" fill="{INK}"/>{mark()}')
(OUT / 'omashot-app.svg').write_text(app)
font = TTFont(os.environ.get('OMASHOT_BRAND_FONT', '/usr/share/fonts/noto/NotoSans-Bold.ttf'))
glyphs = font.getGlyphSet()
cmap = font.getBestCmap()
scale = 68 / font['head'].unitsPerEm
paths, cursor = [], 0
for char in 'OmaShot':
    name = cmap[ord(char)]
    pen = SVGPathPen(glyphs)
    glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, cursor, 98)))
    paths.append(f'<path d="{pen.getCommands()}"/>')
    cursor += font['hmtx'][name][0] * scale - 1.2
width = round(142 + cursor + 20)
for suffix, color in [('dark', INK), ('light', '#ffffff')]:
    lockup = f'<g transform="translate(0 4) scale(.53)">{mark()}</g><g transform="translate(142 0)" fill="{color}">{"".join(paths)}</g>'
    (OUT / f'omashot-logo-{suffix}.svg').write_text(svg(lockup, f'0 0 {width} 144'))
for size in (16, 24, 32, 48, 64, 128, 256, 512, 1024):
    subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), str(OUT/'omashot-app.svg'), '-o', str(OUT/f'omashot-{size}.png')], check=True)
# Preview on both surfaces, plus actual-size app icons, with outlined wordmarks.
def inline(path, x, y, w, h):
    import re
    source = path.read_text()
    body = re.sub(r'^<svg[^>]*>|</svg>\s*$', '', source)
    vb = re.search(r'viewBox="([^"]+)"', source).group(1)
    return f'<svg x="{x}" y="{y}" width="{w}" height="{h}" viewBox="{vb}">{body}</svg>'
board = '<rect width="1000" height="660" rx="28" fill="#f6f3ef"/><path d="M0 330H1000V632Q1000 660 972 660H28Q0 660 0 632Z" fill="#171b29"/>'
board += inline(OUT/'omashot-logo-dark.svg', 60, 48, 550, 160)
board += inline(OUT/'omashot-logo-light.svg', 60, 378, 550, 160)
board += inline(OUT/'omashot-app.svg', 716, 64, 208, 208)
for x, size in ((66,16),(112,24),(166,32),(228,48),(306,64)):
    board += inline(OUT/'omashot-app.svg', x, 252-size/2, size, size)
for x, size in ((66,16),(112,24),(166,32),(228,48),(306,64)):
    board += inline(OUT/'omashot-app.svg', x, 582-size/2, size, size)
board += inline(OUT/'omashot-mark.svg', 716, 394, 208, 208)
(OUT/'brand-preview.svg').write_text(svg(board,'0 0 1000 660'))
subprocess.run(['rsvg-convert', str(OUT/'brand-preview.svg'), '-o', str(OUT/'brand-preview.png')], check=True)
