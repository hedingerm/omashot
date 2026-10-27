#!/usr/bin/env python3
"""Responsiveness regression (offscreen): every edit shows in the live scene synchronously, without waiting for a backend
render, and the live layout agrees with the exact render that later replaces it."""
import json,os,pathlib,shutil,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
binary=root/'target/debug/omashot'
with tempfile.TemporaryDirectory(prefix='omashot-live-test-') as td:
 td=pathlib.Path(td);plugin=td/'plugin';shutil.copytree(root/'plugin',plugin)
 env=dict(os.environ,QT_QPA_PLATFORM='offscreen',XDG_CONFIG_HOME=str(td/'config'),XDG_DATA_HOME=str(td/'data'),OMASHOT_BACKEND=str(binary))
 source=td/'fixture.png';subprocess.run(['magick','-size','900x600','xc:white','-fill','#5865f2','-draw','rectangle 300,200 600,400',str(source)],check=True)
 # Edits autosave over history captures only, so the fixture is imported like a capture.
 def capture():return json.loads(subprocess.check_output([str(binary),'import',str(source)],env=env,text=True))['path']
 env['OMASHOT_SOURCE']=capture()
 (plugin/'LiveSmoke.qml').write_text('''import QtQuick
import Quickshell
ShellRoot { FloatingWindow {id:win;visible:true;implicitWidth:1200;implicitHeight:800
 Editor {id:edit;anchors.fill:parent;sourcePath:Quickshell.env("OMASHOT_SOURCE");backend:Quickshell.env("OMASHOT_BACKEND")
  onError:function(message){console.error("TEST_ERROR="+message);Qt.quit()}}
 property int phase:0
 function require(ok,message){if(!ok){console.error("TEST_ERROR="+message);Qt.quit();throw new Error(message)}}
 // Each edit must be visible in the same tick: the live scene is shown and reflects the new state before any render.
 function live(message){require(edit.liveShown&&!edit.previewReady,message+" shows live immediately")}
 Timer {interval:50;repeat:true;running:true;onTriggered:{
  if(!edit.previewReady||edit.busy)return
  // Once the exact render is current, its size and content mapping must equal the live layout.
  var e=edit.exactRect,c=edit.contentRect
  win.require(e.w===edit.renderedWidth&&e.h===edit.renderedHeight&&["x","y","w","h"].every(function(k){return e.content[k]===c[k]}),"live layout matches exact render at phase "+win.phase+": "+JSON.stringify(e)+" vs "+JSON.stringify(c)+" "+edit.renderedWidth+"x"+edit.renderedHeight)
  var p=win.phase++
  if(p===0){edit.add({type:"rectangle",x:40,y:40,w:200,h:100,width:5,color:"#ff0033"});win.live("draw")}
  else if(p===1){edit.beginGesture(0,50,50);edit.moveGesture(150,130);win.live("move");edit.endGesture()}
  else if(p===2){edit.beginGesture(0,0,0);edit.resizeGesture("se",500,400);win.live("resize");edit.endGesture()}
  else if(p===3){edit.undo();win.live("undo")}
  else if(p===4){edit.redo();win.live("redo")}
  else if(p===5){edit.draft={type:"arrow",x:10,y:10,x2:300,y2:200,width:6,color:"#00aa55"};win.require(edit.liveShown,"draft shows live while the exact render stays current");edit.draft=null;edit.add({type:"arrow",x:10,y:10,x2:300,y2:200,width:6,color:"#00aa55"})}
  else if(p===6){var bg=Object.assign({},edit.backgroundControl.defaults(),{padding:96,radius:20});edit.updateBackground(bg);win.live("background")
   win.require(edit.renderedWidth===900+192&&edit.renderedHeight===600+192&&edit.contentRect.x===96,"background layout applied before the backend render")}
  else if(p===7){var b=Object.assign({},edit.backgroundOperation(),{padding:40,inset:12,alignment:"top-left",aspect_ratio:1.5});edit.updateBackground(b);win.live("background layout")}
  else if(p===8){edit.cropTransform({type:"rotate",angle:90});win.live("rotate");win.require(edit.liveStage.transform&&edit.liveStage.transform.type==="rotate","pending transform drawn live")}
  else if(p===9){edit.add({type:"crop",x:50,y:50,w:400,h:300,background_color:"#00000000"});win.live("crop")}
  else if(p===10){edit.undo();win.live("undo transform")}
  else{console.log("LIVE_SMOKE_PASS phases="+p);Qt.quit()}
 }}
 Timer {interval:60000;running:true;onTriggered:{console.error("TEST_ERROR=timeout phase "+win.phase);Qt.quit()}}
}}
''')
 out=subprocess.run(['qs','-p',str(plugin/'LiveSmoke.qml')],env=env,capture_output=True,text=True,timeout=90)
 log=out.stdout+out.stderr
 assert 'LIVE_SMOKE_PASS' in log and 'TEST_ERROR' not in log and 'TypeError' not in log and 'ReferenceError' not in log,log[-4000:]
 # Autosave: edits settle into the capture itself without Done; leaving a capture flushes its pending edits.
 first,second=capture(),capture();env.update(OMASHOT_FIRST=first,OMASHOT_SECOND=second)
 (plugin/'AutosaveSmoke.qml').write_text('''import QtQuick
import Quickshell
ShellRoot { FloatingWindow {visible:true;implicitWidth:900;implicitHeight:700
 Editor {id:edit;anchors.fill:parent;sourcePath:Quickshell.env("OMASHOT_FIRST");backend:Quickshell.env("OMASHOT_BACKEND")
  property int saves:0
  onError:function(message){console.error("TEST_ERROR="+message);Qt.quit()}
  onSaved:function(path){console.error("TEST_ERROR=unexpected finish");Qt.quit()}
  onAutosaved:function(path){saves++;console.log("AUTOSAVED="+path)
   if(saves===1){edit.add({type:"filled",x:10,y:10,w:30,h:30,color:"#00ff00"});edit.editText(60,60,-1);edit.inlineEditor.text="Typed";edit.sourcePath=Quickshell.env("OMASHOT_SECOND");if(edit.textEditing){console.error("TEST_ERROR=text editor stays open on the next capture");Qt.quit()}}
   else if(saves===2)Qt.quit()}}
 Timer {interval:50;repeat:true;running:true;property bool done:false
  onTriggered:{if(done||edit.busy||edit.savedOperations==="")return;done=true;edit.add({type:"filled",x:300,y:200,w:50,h:50,color:"#ff0000"})}}
 Timer {interval:20000;running:true;onTriggered:{console.error("TEST_ERROR=autosave timeout");Qt.quit()}}
}}
''')
 out=subprocess.run(['qs','-p',str(plugin/'AutosaveSmoke.qml')],env=env,capture_output=True,text=True,timeout=30)
 log=out.stdout+out.stderr
 assert 'TEST_ERROR' not in log and log.count('AUTOSAVED='+first)==2,log[-4000:]
 project=json.loads(subprocess.check_output([str(binary),'project',first],env=env,text=True))
 assert [o['color'] for o in project['operations'][:2]]==['#ff0000','#00ff00'] and project['operations'][2]['text']=='Typed',project
 pixel=lambda p,x,y:subprocess.check_output(['magick',p,'-format',f'%[hex:p{{{x},{y}}}]','info:'],text=True).strip()
 assert pixel(first,320,220).startswith('FF0000') and pixel(first,20,20).startswith('00FF00'),(pixel(first,320,220),pixel(first,20,20))
 assert pixel(project['source'],320,220).startswith('5865F2'),'original pixels kept in the sidecar'
 assert not pathlib.Path(second).with_suffix('.project.json').exists(),'untouched capture stays unsaved'
print('PASS: draw, move, resize, undo/redo, drafts, background and transforms show live in the same tick; live layout matches the exact render; edits (including text being typed) autosave in place and flush when leaving a capture')
