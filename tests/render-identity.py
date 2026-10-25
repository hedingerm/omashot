#!/usr/bin/env python3
"""Pixel identity of `omashot render` against a baseline revision: ~650 cases (png/rgba/jpg/gray/16-bit/palette inputs ×
every annotation type, op chains and background layouts) must decode to the same RGBA as the baseline binary.

Usage: tests/render-identity.py [--base REF] [--binary PATH] [--base-binary PATH] [-j N]
Default: compares target/release/omashot with REF=HEAD, built in a temporary worktree (target dir target/render-identity).
Use it for refactors and performance work in the render path; intended output changes need a new background version."""
import concurrent.futures as cf,hashlib,json,os,pathlib,subprocess,sys,tempfile
root=pathlib.Path(__file__).resolve().parents[1];args=sys.argv[1:]
def opt(name,default):return args[args.index(name)+1] if name in args else default
base,binary,jobs=opt('--base','HEAD'),opt('--binary',str(root/'target/release/omashot')),int(opt('-j',str(os.cpu_count() or 4)))
def sh(*a,**k):return subprocess.run([str(x) for x in a],check=True,capture_output=True,**k)
with tempfile.TemporaryDirectory(prefix='omashot-identity-') as td:
 td=pathlib.Path(td);reference=opt('--base-binary',None)
 if not reference:
  wt=td/'base';sh('git','-C',root,'worktree','add','--detach',wt,base)
  try:sh('cargo','build','--release','--locked','--quiet',cwd=wt,env=dict(os.environ,CARGO_TARGET_DIR=str(root/'target/render-identity')))
  finally:subprocess.run(['git','-C',str(root),'worktree','remove','--force',str(wt)],capture_output=True)
  reference=str(root/'target/render-identity/release/omashot')
 inp=td/'in';inp.mkdir();I={}
 def mk(name,*a):p=inp/name;sh('magick',*a,p);I[name]=str(p)
 # Synthetic screen-like source: noise texture, UI blocks and text.
 mk('big.png','-seed','7','-size','960x540','plasma:#1a1b26-#7aa2f7','-resize','3840x2160!','-fill','#e0e0e0','-draw','rectangle 200,150 1800,900','-fill','#22c55e','-draw','roundrectangle 2000,300 3400,1200 40,40','-fill','#111111','-pointsize','64','-annotate','+260,400','Synthetic 100% @x','-define','png:color-type=2')
 cap=I['big.png']
 mk('rgb.png',cap,'-crop','640x400+300+200','+repage','-define','png:color-type=2')
 mk('rgba.png',cap,'-crop','640x400+900+500','+repage','-alpha','set','-channel','A','-fx','0.3+0.7*i/w','+channel','-define','png:color-type=6')
 mk('photo.jpg',cap,'-crop','500x360+100+100','+repage','-quality','85')
 mk('gray.png',cap,'-crop','400x300+50+50','+repage','-colorspace','gray','-depth','8')
 mk('grayrgb.png',cap,'-crop','400x300+50+50','+repage','-colorspace','gray','-colorspace','sRGB','-depth','8','-define','png:color-type=2')
 mk('white.png','-size','300x200','xc:white','-define','png:color-type=2')
 mk('pad.png','-size','300x200','xc:white','-fill','#202020','-draw','rectangle 20,30 200,90','-define','png:color-type=2')
 mk('deep.png',cap,'-crop','320x200+10+10','+repage','-depth','16')
 sh('magick',cap,'-crop','320x200+700+300','+repage','-colors','40','PNG8:'+str(inp/'pal.png'));I['pal.png']=str(inp/'pal.png')
 mk('tiny.png','-size','20x15','gradient:red-blue')
 mk('layer.png','-size','90x60','gradient:#ff000080-#00ff00ff','-define','png:color-type=6')
 mk('wall.jpg','-size','400x300','plasma:fractal','-seed','1')
 L,W=I['layer.png'],I['wall.jpg']
 T=lambda **k:{**dict(type='text',x=12,y=14,text='Hello 100% @x',size=26,color='#345ac8'),**k}
 single=[
  dict(type='rectangle',x=20,y=20,w=150,h=90,color='#ef4444',width=4),dict(type='rectangle',x=-10,y=-10,w=80,h=60,color='#ef444480',width=9),
  dict(type='filled',x=40,y=30,w=100,h=80,color='#22c55e'),dict(type='filled',x=40,y=30,w=100,h=80,color='#22c55e66'),
  dict(type='ellipse',x=30,y=40,w=160,h=90,color='#3b82f6',width=5),
  dict(type='line',x=5,y=5,x2=200,y2=150,color='#ff00ff',width=3),dict(type='line',x=5.5,y=5.25,x2=200.75,y2=150.5,color='#ff00ff80',width=13),
  dict(type='arrow',x=20,y=150,x2=220,y2=30,color='#ef4444',width=4),dict(type='arrow',x=10,y=80,cx=100,cy=-20,x2=200,y2=90,color='#123456cc',width=6),
  dict(type='freehand',points=[dict(x=10+i*2,y=50+(i*7)%40) for i in range(150)],color='#f97316',width=5),
  dict(type='freehand',smooth=False,points=[dict(x=10+i*2,y=50+(i*7)%40) for i in range(150)],color='#f9731680',width=8),
  dict(type='freehand',points=[dict(x=10+(i%300),y=20+i/20) for i in range(1203)],color='#0ea5e9',width=2),
  dict(type='step',x=60,y=60,text='3',size=30,color='#ef4444'),dict(type='step',x=60,y=60,size=50,color='#8b5cf680'),
  *[T(style=s) for s in ['standard','outlined','boxed','rounded_boxed','monospaced','monospaced_boxed','rounded']],T(style='boxed',w=200,h=40,color='#00000099'),
  dict(type='rotate',angle=90),dict(type='rotate',angle=33),dict(type='rotate',angle=-17.5),dict(type='rotate',angle=180),
  dict(type='flip',axis='horizontal'),dict(type='flip',axis='vertical'),dict(type='resize',w=213,h=117),dict(type='resize',w=900,h=500),
  dict(type='crop',x=10,y=20,w=150,h=100),dict(type='crop',x=-30,y=-20,w=400,h=300,background_color='#ff000080'),dict(type='crop',x=-30,y=-20,w=400,h=300),
  dict(type='image',path=L,x=20,y=30,w=90,h=60),dict(type='image',path=L,x=250,y=150,w=180,h=120),dict(type='redact',x=10,y=10,w=60,h=40),
  dict(type='pixelate',x=15,y=12,w=130,h=70,strength=12),dict(type='pixelate',x=0,y=0,w=5000,h=5000,strength=64),
  dict(type='blur',x=20,y=20,w=120,h=80,strength=12),dict(type='blur',x=0,y=0,w=60,h=50,strength=80),dict(type='blur',x=150,y=100,w=9000,h=9000,strength=1),
  dict(type='blur',x=0,y=0,w=9000,h=9000,strength=30),dict(type='blur',x=3,y=170,w=40,h=40,strength=5),
  dict(type='highlight',x=10,y=10,w=200,h=30,color='#ffe629'),dict(type='highlight',x=10,y=10,w=200,h=30,color='#00ff0080',opacity=0.8,radius=4),
  dict(type='spotlight',x=40,y=40,w=150,h=90,radius=12),dict(type='spotlight',x=0,y=0,w=50,h=50,radius=0),
 ]
 chains=[
  [dict(type='rotate',angle=33),T(style='standard'),dict(type='rectangle',x=5,y=5,w=50,h=50,color='#ff0000')],
  [dict(type='rectangle',x=20,y=20,w=150,h=90,color='#777777'),dict(type='rotate',angle=33),dict(type='line',x=10,y=10,x2=150,y2=100,color='#00000080',width=5),T(style='boxed',color='#333333')],
  [dict(type='arrow',x=10,y=10,x2=90,y2=90),dict(type='text',x=20,y=20,text='Test 100%'),dict(type='redact',x=3,y=3,w=10,h=10),dict(type='background',padding=20,preset=2,shadow=True)],
  [dict(type='ellipse',x=30,y=40,w=160,h=90,color='#3b82f680',width=12),dict(type='filled',x=60,y=50,w=100,h=80,color='#22c55e80'),dict(type='rectangle',x=50,y=45,w=100,h=80,color='#ef444480',width=20),dict(type='highlight',x=40,y=40,w=150,h=40),dict(type='arrow',x=0,y=0,cx=90,cy=200,x2=180,y2=20,color='#ffffff88',width=7)],
  [dict(type='flip',axis='horizontal'),dict(type='flip',axis='vertical'),dict(type='resize',w=333,h=222),dict(type='step',x=30,y=30),dict(type='blur',x=0,y=0,w=100,h=100,strength=20),dict(type='rotate',angle=90),T(style='outlined')],
  [dict(type='crop',x=-20,y=-20,w=300,h=250,background_color='#00000000'),dict(type='rotate',angle=21),dict(type='filled',x=0,y=0,w=40,h=40,color='#00ff0088'),dict(type='image',path=L,x=200,y=200,w=120,h=80),dict(type='rectangle',x=1,y=1,w=30,h=30)],
  [dict(type='pixelate',x=0,y=0,w=100,h=100),dict(type='rectangle',x=10,y=10,w=60,h=60,color='#000000'),dict(type='spotlight',x=20,y=20,w=100,h=100),T(style='monospaced_boxed',color='#ffffff'),dict(type='background',gradient_version=2,preset=7,padding=40,radius=16,shadow_blur=10)],
  [dict(type='rectangle',x=10+i*7,y=10+i*5,w=80,h=50,color=['#ef4444','#22c55e80','#3b82f6','#ffffff','#00000040'][i%5],width=1+i%6) for i in range(12)],
 ]
 BG=lambda **k:dict(type='background',**k)
 bgs=[BG(),BG(preset=5),BG(gradient_version=2,preset=3),BG(gradient_version=2,preset=12,auto_balance=False),BG(gradient_version=2,preset=18,radius=12,inset=10,inset_color='#ffffff80'),
  BG(mode='solid',background_color='#123456'),BG(mode='solid',background_color='#12345680',shadow=False),BG(mode='wallpaper',image_path=W),BG(mode='wallpaper',image_path=W,blur=7),
  BG(mode='blurred'),BG(mode='blurred',image_path=W,blur=40),BG(mode='blurred',blur=0),
  BG(padding=0,shadow=False,radius=0),BG(padding=0),BG(padding=200,aspect_ratio=1),BG(aspect_ratio=2.35,alignment='top-left'),BG(aspect_ratio=0.5,alignment='bottom-right'),
  *[BG(gradient_version=2,preset=9,aspect_ratio=1.5,alignment=a,padding=30) for a in ['top','top-right','left','right','bottom-left','bottom','center']],
  BG(shadow_blur=0),BG(shadow_blur=5,shadow_strength=1),BG(shadow_blur=60),BG(shadow_blur=100,padding=10),BG(shadow_offset=-100,shadow_offset_x=100,padding=20),
  BG(shadow_offset=100,shadow_offset_x=-100,padding=5,shadow_blur=30),BG(radius=300,inset=200,padding=8,shadow_strength=0.9),BG(padding=2000,shadow_blur=2),
  BG(gradient_version=2,preset=0,padding=64,radius=12,shadow=True),
 ]
 cases=[]
 for name in ['rgb.png','rgba.png','photo.jpg','gray.png','grayrgb.png','white.png','deep.png','pal.png']:
  cases+=[(name,f's{i}',[o]) for i,o in enumerate(single)]+[(name,f'c{i}',c) for i,c in enumerate(chains)]
 for name in ['rgb.png','rgba.png','pad.png','tiny.png','photo.jpg','gray.png']:cases+=[(name,f'b{i}',[b]) for i,b in enumerate(bgs)]
 cases+=[('tiny.png','none',[]),('white.png','none',[]),('big.png','none',[]),('big.png','bgdef',[BG(gradient_version=2,preset=3,padding=64,radius=12)]),
  ('big.png','bgblur',[BG(mode='blurred')]),('big.png','bgshadow60',[BG(shadow_blur=60,padding=100)]),
  ('big.png','blurop',[dict(type='blur',x=100,y=100,w=900,h=500,strength=40),dict(type='blur',x=2000,y=1000,w=900,h=900,strength=12)]),
  ('big.png','chain',chains[2]+[dict(type='rotate',angle=33)]+chains[3])]
 def run(exe,tag,name,ops):
  d=td/'xdg'/tag;env=dict(os.environ,XDG_DATA_HOME=str(d/'data'),XDG_CONFIG_HOME=str(d/'config'))
  p=subprocess.run([exe,'render',I[name],json.dumps(ops),'--preview'],env=env,capture_output=True,text=True)
  if p.returncode:return ('ERR',p.stdout.strip())
  r=json.loads(p.stdout);path=r.pop('path');return (r,path)
 def pixels(path):return hashlib.sha256(sh('magick',path,'-depth','16','rgba:-').stdout).hexdigest()
 def compare(n,a,b):
  name,cid,_=cases[n]
  if a[0]!='ERR' and b[0]!='ERR':
   # Byte-identical files have identical pixels; decode only when the encodings differ.
   pa,pb=a[1],b[1];same=pathlib.Path(pa).read_bytes()==pathlib.Path(pb).read_bytes()
   a,b=(a[0],'same'),(b[0],'same' if same or pixels(pa)==pixels(pb) else 'pixels differ');os.remove(pa);os.remove(pb)
  return f'{name}:{cid}',a,b
 bad=errors=0
 # Each binary's render is its own task, and the slow 4K cases start first, so no single case is the tail.
 order=sorted(range(len(cases)),key=lambda n:cases[n][0]!='big.png')
 with cf.ThreadPoolExecutor(jobs) as ex:
  jobs={(n,side):ex.submit(run,reference if side=='a' else binary,f'{side}{n}',cases[n][0],cases[n][2]) for n in order for side in 'ab'}
  for n in range(len(cases)):
   k,a,b=compare(n,jobs[n,'a'].result(),jobs[n,'b'].result())
   if a!=b:bad+=1;print('DIFF',k,a,b,flush=True)
   elif a[0]=='ERR':errors+=1;print('ERR (both)',k,a[1][:120])
 print(f'{len(cases)} cases, {bad} differ, {errors} rejected by both binaries')
 if bad or errors>len(cases)//10:sys.exit(1)
print(f'PASS: render output pixel-identical to {base if "--base-binary" not in args else "the base binary"}')
