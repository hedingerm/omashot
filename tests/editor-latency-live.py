#!/usr/bin/env python3
"""Live Wayland: input-to-display latency of editor interactions, driven by real pointer/keyboard events.
Default: a standalone `qs -p plugin` with temporary XDG dirs. `--shell` measures the installed plugin inside the running
omarchy-shell instead (imports one synthetic capture into the real history and deletes it afterwards).
Moves the real pointer and fullscreens the OmaShot window for ~1 minute. Prints per-interaction latency stats as JSON;
`--max-ms N` fails when any interaction's p90 exceeds N."""
import base64,json,os,pathlib,subprocess,sys,tempfile,time
root=pathlib.Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'tests'))
import vpointer
args=sys.argv[1:];shell='--shell' in args
plugin=pathlib.Path(args[args.index('--plugin')+1]) if '--plugin' in args else root/'plugin'
limit=float(args[args.index('--max-ms')+1]) if '--max-ms' in args else 0
backend=str(root/'target/release/omashot') if (root/'target/release/omashot').exists() else str(root/'target/debug/omashot')
td=pathlib.Path(tempfile.mkdtemp(prefix='omashot-latency-'))
env=dict(os.environ,XDG_DATA_HOME=str(td/'data'),XDG_CONFIG_HOME=str(td/'config'),OMASHOT_BACKEND=backend)
proc=None
if shell:
 out=subprocess.run(['qs','list','--all'],capture_output=True,text=True).stdout
 instance=[l.split()[1].rstrip(':') for l in out.splitlines() if l.startswith('Instance')]
 target=['-i',next(i for i in instance if 'omashot' in subprocess.run(['qs','ipc','-i',i,'show'],capture_output=True,text=True).stdout)]
 pid=int(next(l.split(':')[1] for l in out.split('Instance '+target[1])[1].splitlines() if 'Process ID' in l))
 backend='omashot';env=dict(os.environ)
else:
 proc=subprocess.Popen(['qs','-p',str(plugin)],env=env,stdout=open(td/'qs.log','w'),stderr=subprocess.STDOUT);target=['-p',str(plugin)];pid=proc.pid;time.sleep(1.5)
def ipc(*a):
 r=subprocess.run(['qs','ipc']+target+['call','omashot']+list(a),capture_output=True,text=True,timeout=10)
 if r.returncode:raise RuntimeError(r.stderr)
 return r.stdout.strip()
def status():return json.loads(ipc('status'))
def wait(cond,timeout=10):
 end=time.time()+timeout
 while time.time()<end:
  if cond():return True
  time.sleep(.1)
 raise RuntimeError('timeout')
W,H=2560,1440
sample=td/'sample.png'
subprocess.run(['magick','-size',f'{W}x{H}','gradient:#f4f6fb-#dfe5f1','-fill','#2b3245','-draw','rectangle 0,0 2560,56','-fill','#ffffff','-draw','roundrectangle 160,140 1240,820 18,18','-draw','roundrectangle 1320,140 2400,1300 18,18','-fill','#5865f2','-draw','rectangle 220,200 900,260','-fill','#9aa3b5']+sum([['-draw',f'rectangle 220,{320+i*60} {1100-i*37},{340+i*60}']for i in range(8)],[])+[str(sample)],check=True)
def ops(n,background):
 kinds=['rectangle','arrow','text','highlight','pixelate','ellipse','freehand','filled','line','step']
 out=[]
 for i in range(n):
  k=kinds[i%len(kinds)];x=120+(i*197)%(W-500);y=120+(i*131)%(H-400)
  o={'type':k,'x':x,'y':y,'w':260,'h':120,'x2':x+260,'y2':y+120,'color':'#ff657a','width':6,'size':32,'text':'Note %d'%i,'style':'standard','strength':12}
  if k=='freehand':o['points']=[{'x':x+j*12,'y':y+40+((j*37)%60)}for j in range(24)]
  if k=='step':o['text']=str(i+1)
  out.append(o)
 if background:out.append({'type':'background','mode':'gradient','preset':2,'gradient_version':2,'padding':64,'inset':0,'radius':12,'shadow':True,'shadow_strength':.35,'blur':0,'alignment':'center','auto_balance':True,'aspect_ratio':0})
 return out
results={};captured=None
try:
 if not shell:wait(lambda:'status' in ipc('status'),10)
 before=status()['current'];started=time.time();ipc('importImage',str(sample));wait(lambda:status()['current'] not in ('',before))
 captured=status()['current'];ipc('annotate');wait(lambda:status()['editing'])
 if not status().get('fullscreen'):ipc('expand')
 time.sleep(1.5)
 client=next(c for c in json.loads(subprocess.run(['hyprctl','clients','-j'],capture_output=True,text=True).stdout) if c['title']=='OmaShot' and c['pid']==pid)
 mon=next(m for m in json.loads(subprocess.run(['hyprctl','monitors','-j'],capture_output=True,text=True).stdout) if m['focused'])
 ptr=vpointer.Pointer(mon['x']+mon['width']/mon['scale'],mon['y']+mon['height']/mon['scale'])
 def glob(rect,x,y):return client['at'][0]+rect['x']+x,client['at'][1]+rect['y']+y
 def img(sx,sy):
  r=json.loads(ipc('editorRect','image'));return glob(r,(sx-r['sourceX'])*r['sx'],(sy-r['sourceY'])*r['sx'])
 def settle():
  wait(lambda:(lambda r:r['pending']==0 and r['idle'])(json.loads(ipc('editorLatency'))),60);time.sleep(.4)
 def measure(label,n,background):
  ipc('editorLatencyReset');ipc('editorSetup','select',base64.b64encode(json.dumps(ops(n,background)).encode()).decode());settle();ipc('editorLatencyReset')
  print(label,'operations',json.loads(ipc('editorLatency'))['operations'],file=sys.stderr)
  # Draw a rectangle across empty canvas.
  ipc('editorSetup','rectangle','');time.sleep(.2)
  ptr.drag([img(300+i*20,1000+i*6) for i in range(40)]);settle()
  # Move the drawn rectangle (selected after drawing) by its edge, then resize via its south-east handle.
  ipc('editorSetup','select','');time.sleep(.2)
  ptr.drag([img(600+i*12,1100+i*4) for i in range(40)]);settle()
  ptr.drag([img(300+39*12+780-i*8,1000+39*4+234-i*3) for i in range(40)]);settle()
  # Undo/redo with the keyboard.
  for key in ['z','z','z']:subprocess.run(['wtype','-M','ctrl',key,'-m','ctrl']);time.sleep(.6)
  for key in ['z','z']:subprocess.run(['wtype','-M','ctrl','-M','shift',key,'-m','shift','-m','ctrl']);time.sleep(.6)
  # Drag the padding slider.
  s=json.loads(ipc('editorRect','slider-padding'));print('slider',s,file=sys.stderr)
  if s:ptr.drag([glob(s,8+i*(s['w']-16)/40,s['h']/2) for i in range(41)]);settle()
  results[label]={k:v for k,v in json.loads(ipc('editorLatency')).items() if isinstance(v,dict)}
 for n,bg in [(0,False),(10,True),(30,True)]:measure(f'{n} annotations'+(' + background' if bg else ''),n,bg)
 ptr.close()
finally:
 try:
  if status().get('editing'):ipc('editorSetup','select',base64.b64encode(b'[]').decode())
  ipc('expand');ipc('dismiss')
 except Exception as e:print('cleanup:',e,file=sys.stderr)
 if shell and captured and '/omashot/' in captured:
  subprocess.run([backend,'delete',captured],capture_output=True)
  for f in pathlib.Path(captured).parent.glob('.preview-*.png'):
   if f.stat().st_mtime>=started:f.unlink()
 if proc:proc.kill()
print(json.dumps(results,indent=1))
# Input that never reached the window (focus stolen, pointer outside) records nothing; that is a failure, not a pass.
kinds={'draw-move','draw-commit','move','resize','undo','redo','background'}
unmeasured={k:sorted(kinds-set(r)) for k,r in results.items() if kinds-set(r)}
assert len(results)==3 and not unmeasured,f'interactions not measured: {unmeasured or "no results"}'
if limit:
 bad=[(k,kind,v['p90Ms']) for k,r in results.items() for kind,v in r.items() if isinstance(v,dict) and v['p90Ms']>limit]
 assert not bad,f'interactions slower than {limit} ms at p90: {bad}'
 print(f'PASS: every editor interaction shows within {limit} ms at p90')
