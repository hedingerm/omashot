#!/usr/bin/env python3
"""Live Wayland (GPU): the editor's live scene must match the exact backend render closely, so swapping to the exact
pixels never visibly pops. Grabs LiveScene at 1:1 for each case and compares it with `omashot render`."""
import concurrent.futures as cf,json,os,pathlib,shutil,subprocess,sys,tempfile
root=pathlib.Path(__file__).resolve().parents[1];binary=root/'target/debug/omashot'
W,H=800,500
bg={'type':'background','mode':'gradient','preset':2,'gradient_version':2,'padding':48,'inset':0,'radius':16,'shadow':True,'shadow_strength':.35,'shadow_blur':18,'shadow_offset':8,'blur':0,'alignment':'center','auto_balance':True,'aspect_ratio':0}
def op(t,**k):
 o={'type':t,'x':120,'y':110,'w':300,'h':160,'x2':520,'y2':330,'color':'#ff657a','width':6,'size':40,'text':'Hello 42','style':'standard','strength':12};o.update(k);return o
cases={
 'rectangle':[op('rectangle')],'filled':[op('filled',color='#3b82f6')],'ellipse':[op('ellipse')],'line':[op('line')],'arrow':[op('arrow')],
 'curved arrow':[op('arrow',cx=200,cy=380)],'freehand':[op('freehand',points=[{'x':120+i*14,'y':200+((i*41)%90)}for i in range(30)])],
 'text':[op('text')],'text boxed':[op('text',style='boxed',w=0,h=0)],'text outlined':[op('text',style='outlined')],'step':[op('step',text='3')],'step centered':[op('step',text='3',centered=True)],'step centered 12':[op('step',text='12',centered=True)],
 'highlight':[op('highlight',color='#ffe629')],'redact':[op('redact')],'pixelate':[op('pixelate')],'blur':[op('blur')],'spotlight':[op('spotlight')],
 'background':[op('rectangle'),bg],'background inset':[op('rectangle'),dict(bg,inset=24,radius=24,preset=7)],'background solid':[dict(bg,mode='solid',background_color='#0ea5e9',shadow_strength=.6,shadow_blur=30)],
 'background top-left':[dict(bg,alignment='top-left',aspect_ratio=1.0,padding=80,preset=12)],
 # Transforms drawn live while their flattened base renders.
 'crop':[op('rectangle'),{'type':'crop','x':-40,'y':60,'w':700,'h':420,'background_color':'#22c55e'},op('ellipse',x=50,y=40)],
 'rotate':[op('arrow'),{'type':'rotate','angle':90},op('rectangle',x=40,y=60)],
 'flip':[op('text'),{'type':'flip','axis':'horizontal'}],'flip vertical':[op('line'),{'type':'flip','axis':'vertical'},bg],
 'resize':[op('rectangle'),{'type':'resize','w':600,'h':300}],
 # Overlay annotations leave the screenshot: white margins without a background, grown padding with one.
 'overlay margin':[op('arrow',x=-90,y=60,x2=300,y2=200,overlay=True),op('text',x=640,y=470,w=150,h=30,text='Note',overlay=True)],
 'overlay padding':[op('rectangle'),op('arrow',x=-30,y=-20,x2=200,y2=150,overlay=True),op('text',x=700,y=-90,w=120,h=30,text='Note',overlay=True),op('highlight',x=-60,y=520,w=200,h=30,color='#ffe629',overlay=True),bg],
 'overlay crop':[op('arrow',x=-60,y=100,x2=200,y2=100,overlay=True),{'type':'crop','x':-80,'y':40,'w':600,'h':400,'background_color':'#22c55e'},op('ellipse',x=50,y=40)],
}
limits={'text outlined':3}
with tempfile.TemporaryDirectory(prefix='omashot-fidelity-') as td:
 td=pathlib.Path(td);plugin=td/'plugin';shutil.copytree(root/'plugin',plugin)
 env=dict(os.environ,XDG_CONFIG_HOME=str(td/'config'),XDG_DATA_HOME=str(td/'data'),OMASHOT_BACKEND=str(binary))
 data=td/'data/omashot';data.mkdir(parents=True)
 source=data/'fixture.png'
 subprocess.run(['magick','-size',f'{W}x{H}','gradient:#f4f6fb-#c9d3e6','-fill','#1f2937','-draw','rectangle 40,40 760,90','-fill','#5865f2','-draw','roundrectangle 60,140 360,420 14,14','-fill','#e11d48','-draw','circle 560,280 640,280',str(source)],check=True)
 gradients=json.loads(subprocess.run([str(binary),'backgrounds'],env=env,capture_output=True,text=True,check=True).stdout)
 # Exact renders run in the background while Quickshell grabs the live scenes.
 def render(ops):return json.loads(subprocess.run([str(binary),'render',str(source),json.dumps(ops),'--preview'],env=env,capture_output=True,text=True,check=True).stdout)
 pool=cf.ThreadPoolExecutor(os.cpu_count() or 4);pending={name:pool.submit(render,ops) for name,ops in cases.items()}
 (plugin/'FidelitySmoke.qml').write_text('''import QtQuick
import Quickshell
ShellRoot { FloatingWindow {id:win;visible:true;implicitWidth:1000;implicitHeight:700;color:"black"
 property var cases:'''+json.dumps(list(cases.items()))+'''
 property int index:0
 LiveScene {id:scene;zoom:1;baseSource:"file://'''+str(source)+'''";baseWidth:'''+str(W)+''';baseHeight:'''+str(H)+''';gradients:'''+json.dumps(gradients)+'''}
 function load(){var ops=win.cases[win.index][1],t=-1;ops.forEach(function(o,i){if(["crop","resize","rotate","flip"].indexOf(o.type)>=0)t=i})
  scene.preOperations=ops.slice(0,Math.max(0,t));scene.transformOp=t>=0?ops[t]:null
  scene.operations=ops.slice(t+1).filter(function(o){return o.type!=="background"});scene.background=ops.filter(function(o){return o.type==="background"})[0]||null}
 Timer {id:tick;interval:500;running:true;onTriggered:{
  var i=win.index;scene.grabToImage(function(result){result.saveToFile("'''+str(td)+'''/live-"+i+".png");win.index++;if(win.index>=win.cases.length){console.log("FIDELITY_DONE");Qt.quit()}else{win.load();tick.restart()}},Qt.size(scene.width/win.devicePixelRatio,scene.height/win.devicePixelRatio))
 }}
 Component.onCompleted:load()
}}
''')
 out=subprocess.run(['qs','-p',str(plugin/'FidelitySmoke.qml')],env=env,capture_output=True,text=True,timeout=120)
 assert 'FIDELITY_DONE' in out.stdout+out.stderr,out.stdout[-3000:]+out.stderr[-3000:]
 expected={name:f.result() for name,f in pending.items()};pool.shutdown()
 bad=[];report=[]
 for i,(name,ops) in enumerate(cases.items()):
  live=td/f'live-{i}.png';exact=expected[name]
  # Fractional scaling rounds the grab up by at most a pixel.
  size=[int(v) for v in subprocess.run(['magick','identify','-format','%w %h',str(live)],capture_output=True,text=True).stdout.split()]
  if not (0<=size[0]-exact['width']<=1 and 0<=size[1]-exact['height']<=1):bad.append(f'{name}: size {size} != {exact["width"]}x{exact["height"]}');continue
  subprocess.run(['magick',str(live),'-crop',f'{exact["width"]}x{exact["height"]}+0+0','+repage','-alpha','off',str(live)],check=True)
  # Mean absolute error in 0-255 levels, and the share of pixels off by more than 25%.
  # Annotation cases are measured around the annotation, so a small mark can't hide in a large unchanged image.
  crop=[] if ops[-1]['type']=='background' or len(ops)>1 else ['-crop','480x340+80+70','+repage']
  def metric(*m):return subprocess.run(['magick','compare',*m,'(',str(live),*crop,')','(',exact['path'],*crop,')','null:'],capture_output=True,text=True).stderr
  mae=float(metric('-metric','MAE').split('(')[1].split(')')[0])*255
  far=int(float(metric('-metric','AE','-fuzz','25%').split()[0]))
  share=100*far/(480*340 if crop else exact['width']*exact['height']);report.append(f'{name:22} MAE {mae:5.2f}  >25%: {share:5.2f}%')
  if mae>limits.get(name,2) or share>.5:bad.append(name)
 print('\n'.join(report))
 if '--keep' in sys.argv:shutil.copytree(td,pathlib.Path(sys.argv[-1]),dirs_exist_ok=True)
 assert not bad,f'live scene differs from the exact render: {bad}'
print('PASS: live scene matches the exact backend render for every operation type and background layout')
