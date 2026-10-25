#!/usr/bin/env python3
"""Use compositor toplevel export; prove real alpha and native-scale dimensions."""
import json,os,pathlib,subprocess,tempfile,time
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='omashot-window-test-') as td:
 td=pathlib.Path(td);env=dict(os.environ,XDG_DATA_HOME=str(td/'data'),XDG_CONFIG_HOME=str(td/'config'),OMASHOT_PLUGIN_PATH=str(root/'plugin'))
 qml=td/'shell.qml';qml.write_text('''import QtQuick
import Quickshell
ShellRoot { FloatingWindow { title:"OmaShot isolated-window fixture";visible:true;implicitWidth:600;implicitHeight:400;color:"transparent"
 Rectangle { anchors.fill:parent;anchors.margins:30;radius:30;color:"#e64c74" }
} }''')
 with (td/'fixture.log').open('w') as log:
  scene=subprocess.Popen(['qs','-p',str(qml)],env=env,stdout=log,stderr=log)
  try:
   deadline=time.monotonic()+10
   while True:
    c=json.loads(subprocess.check_output(['hyprctl','-j','activewindow'],text=True))
    if c.get('title')=='OmaShot isolated-window fixture':break
    if time.monotonic()>deadline:raise AssertionError('Fixture did not become active')
    time.sleep(.1)
   binary=root/'target/debug/omashot'
   subprocess.check_output([str(binary),'config',json.dumps({'window_transparent':True})],env=env)
   result=json.loads(subprocess.check_output([str(binary),'capture','active'],env=env,text=True,timeout=20))
   monitors=json.loads(subprocess.check_output(['hyprctl','-j','monitors'],text=True));scale=next(m['scale'] for m in monitors if m['id']==c['monitor'])
   expected=[round(s*scale) for s in c['size']]
   native=result['captureSource']
   assert all(abs(result[k]-native[k])<=1 for k in ['width','height']),(result,native)
   # Hyprland outer geometry can include borders excluded from the exported client buffer.
   assert all(abs(result[k]-size)<=round(6*scale) for k,size in zip(['width','height'],expected)),(result,expected)
   alpha=float(subprocess.check_output(['magick',result['path'],'-format','%[fx:p{0,0}.a]','info:'],text=True));assert alpha==0,alpha
   color=subprocess.check_output(['magick',result['path'],'-format','%[pixel:p{100,100}]','info:'],text=True);assert '230,76,116' in color,color
  finally:
   scene.terminate()
   try:scene.wait(timeout=5)
   except subprocess.TimeoutExpired:scene.kill();scene.wait()
print('PASS: isolated compositor window buffer, true transparent margins and native fractional-scale dimensions')
