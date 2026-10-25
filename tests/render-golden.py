#!/usr/bin/env python3
"""Golden pixel checksums for `omashot render`: decoded RGBA must not change by a single value.

Pure-Rust ops (raster effects, crop, image layers, backgrounds) are checked everywhere. ImageMagick
ops depend on the magick build and fonts, so they are only checked when those match the golden key.
`--update` rewrites tests/render-golden.json from the current binary; only use it for intended
output changes or after an ImageMagick/font upgrade, never to silence a refactoring diff.
"""
import hashlib,json,os,pathlib,struct,subprocess,sys,tempfile,zlib
root=pathlib.Path(__file__).resolve().parents[1];golden_path=root/'tests/render-golden.json'
binary=os.environ.get('OMASHOT_BACKEND',str(root/'target/debug/omashot'))
def png(path,w,h,channels,pixel,depth=8):
 kind={1:0,3:2,4:6}[channels];fmt='>'+'H'*channels if depth==16 else None
 rows=b''.join(b'\0'+b''.join(struct.pack(fmt,*pixel(x,y)) if fmt else bytes(pixel(x,y)) for x in range(w)) for y in range(h))
 chunk=lambda t,d:struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d))
 path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,depth,kind,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))
 return str(path)
def key():
 fonts=[subprocess.check_output(['fc-match','-f','%{file}',f],text=True) for f in ['sans','monospace','sans:weight=bold']]
 return subprocess.check_output(['magick','-version'],text=True).splitlines()[0]+' | '+' '.join(fonts)
with tempfile.TemporaryDirectory(prefix='omashot-golden-') as directory:
 d=pathlib.Path(directory);env=dict(os.environ,XDG_DATA_HOME=str(d/'data'),XDG_CONFIG_HOME=str(d/'config'))
 I={'rgb':png(d/'rgb.png',160,100,3,lambda x,y:(x*255//159,y*255//99,(x*y)%256) if not(40<x<90 and 30<y<60) else (24,24,32)),
  'rgba':png(d/'rgba.png',120,90,4,lambda x,y:(200,(x*2)%256,y*2,40+y*2)),
  'gray':png(d/'gray.png',100,80,1,lambda x,y:((x^y)*3%256,)),
  'deep':png(d/'deep.png',80,60,3,lambda x,y:(x*800,y*1000,(x*y*37)%65536),16),
  'pad':png(d/'pad.png',120,90,3,lambda x,y:(32,32,32) if 10<x<70 and 20<y<50 else (255,255,255))}
 layer=png(d/'layer.png',30,20,4,lambda x,y:(255,x*8,y*12,128+y*6));wall=png(d/'wall.png',64,48,3,lambda x,y:(x*4,y*5,(x+y)*2))
 T=lambda **k:{**dict(type='text',x=8,y=10,text='Ab 100% @x',size=18,color='#345ac8'),**k}
 BG=lambda **k:dict(type='background',**k)
 rust=[[],[dict(type='redact',x=5,y=5,w=40,h=20)],[dict(type='pixelate',x=10,y=10,w=70,h=50,strength=8)],[dict(type='pixelate',x=0,y=0,w=5000,h=5000,strength=64)],
  [dict(type='blur',x=20,y=15,w=60,h=40,strength=6)],[dict(type='blur',x=0,y=0,w=9000,h=9000,strength=30)],[dict(type='blur',x=50,y=50,w=900,h=900,strength=1)],
  [dict(type='highlight',x=5,y=5,w=90,h=20)],[dict(type='highlight',x=5,y=5,w=90,h=20,color='#00ff0080',opacity=0.8,radius=3)],
  [dict(type='spotlight',x=20,y=20,w=60,h=40,radius=8)],[dict(type='crop',x=-10,y=-5,w=140,h=120,background_color='#ff000080')],[dict(type='crop',x=10,y=10,w=50,h=40)],
  [dict(type='image',path=layer,x=10,y=10,w=30,h=20)],[dict(type='image',path=layer,x=70,y=60,w=60,h=40)],
  [BG()],[BG(preset=5,shadow_blur=0)],[BG(gradient_version=2,preset=3)],[BG(gradient_version=2,preset=12,auto_balance=False,radius=10,inset=6)],
  [BG(mode='solid',background_color='#12345680',shadow_strength=1,shadow_blur=4)],[BG(mode='wallpaper',image_path=wall,blur=5)],[BG(mode='blurred',padding=20)],
  [BG(padding=0,shadow=False)],[BG(aspect_ratio=2,alignment='top-left',shadow_offset=-30,shadow_offset_x=40)],[BG(aspect_ratio=0.6,alignment='bottom',shadow_blur=60,padding=10)],
  [dict(type='pixelate',x=0,y=0,w=50,h=50),dict(type='crop',x=-5,y=-5,w=100,h=80),dict(type='blur',x=0,y=0,w=40,h=40,strength=12),BG(gradient_version=2,preset=7,padding=24,radius=8)]]
 magick=[[dict(type='rectangle',x=10,y=10,w=60,h=40,color='#ef444480',width=6)],[dict(type='filled',x=20,y=15,w=50,h=30,color='#22c55e')],
  [dict(type='ellipse',x=15,y=20,w=70,h=40,color='#3b82f6',width=3)],[dict(type='line',x=2.5,y=3,x2=90,y2=70.25,color='#f0f',width=7)],
  [dict(type='arrow',x=10,y=70,x2=110,y2=15,color='#ef4444',width=4)],[dict(type='arrow',x=5,y=40,cx=60,cy=-10,x2=110,y2=45,color='#123456cc',width=5)],
  [dict(type='freehand',points=[dict(x=5+i*2,y=30+(i*7)%30) for i in range(60)],color='#f97316',width=4)],
  [dict(type='freehand',smooth=False,points=[dict(x=5+i*2,y=30+(i*7)%30) for i in range(60)],color='#f9731680',width=6)],
  [dict(type='step',x=30,y=30,text='3',size=20,color='#ef4444')],[dict(type='step',x=40,y=35,text='12',size=24,color='#6c5ce7',centered=True)],
  *[[T(style=s)] for s in ['standard','outlined','boxed','rounded_boxed','monospaced','monospaced_boxed','rounded']],
  [dict(type='rotate',angle=90)],[dict(type='rotate',angle=33)],[dict(type='flip',axis='horizontal')],[dict(type='flip',axis='vertical')],[dict(type='resize',w=77,h=51)],
  [dict(type='rotate',angle=33),T(),dict(type='filled',x=0,y=0,w=20,h=20,color='#00ff0088')],
  [dict(type='rectangle',x=10,y=10,w=50,h=40,color='#777777'),dict(type='blur',x=0,y=0,w=60,h=60,strength=5),dict(type='arrow',x=0,y=0,x2=80,y2=60),BG(padding=12,preset=2)],
  [dict(type='rectangle',x=5+i*6,y=5+i*4,w=40,h=30,color=['#ef4444','#22c55e80','#ffffff','#00000040'][i%4],width=1+i%5) for i in range(8)]]
 cases=[(f'rust:{n}:{i}',n,o) for n in I for i,o in enumerate(rust)]+[(f'magick:{n}:{i}',n,o) for n in I for i,o in enumerate(magick)]
 def render(name,ops):
  out=subprocess.run([binary,'render',I[name],json.dumps(ops),'--preview'],env=env,capture_output=True,text=True)
  if out.returncode:return 'error: '+out.stdout.strip()
  r=json.loads(out.stdout);path=r.pop('path')
  pixels=subprocess.check_output(['magick',path,'-depth','16','rgba:-']);os.remove(path)
  return json.dumps(r,sort_keys=True)+' '+hashlib.sha256(pixels).hexdigest()
 results={c:render(n,o) for c,n,o in cases}
 if sys.argv[1:]==['--update']:
  golden_path.write_text(json.dumps({'magick':key(),'cases':results},indent=1,sort_keys=True)+'\n');print(f'Wrote {len(results)} golden renders');sys.exit()
 golden=json.loads(golden_path.read_text());same_magick=golden['magick']==key()
 checked=[c for c in results if same_magick or c.startswith('rust:')]
 bad=[c for c in checked if results[c]!=golden['cases'].get(c)]
 assert not bad,'Render output changed: '+', '.join(bad)
 print(f'PASS: {len(checked)} golden renders pixel-identical'+('' if same_magick else f' (skipped {len(results)-len(checked)} ImageMagick renders: magick/fonts differ from golden key)'))
