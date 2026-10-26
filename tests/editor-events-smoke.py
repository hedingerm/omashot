#!/usr/bin/env python3
"""Use Qt's real event path for annotation selection/drag/handles/inline text/crop."""
import os,pathlib,shutil,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='omashot-events-test-') as td:
 td=pathlib.Path(td);plugin=td/'plugin';shutil.copytree(root/'plugin',plugin)
 source=td/'source.png';subprocess.run(['magick','-size','800x500','xc:#f2f4ff',str(source)],check=True)
 env=dict(os.environ,QT_QPA_PLATFORM='offscreen',XDG_CONFIG_HOME=str(td/'config'),XDG_DATA_HOME=str(td/'data'),OMASHOT_BACKEND=str(root/'target/debug/omashot'),OMASHOT_SOURCE=str(source))
 harness=plugin/'EventSmoke.qml'
 harness.write_text('''import QtQuick
import Quickshell
import QtTest
ShellRoot { FloatingWindow {visible:true;implicitWidth:1100;implicitHeight:800
 Editor {id:edit;anchors.fill:parent;sourcePath:Quickshell.env("OMASHOT_SOURCE");backend:Quickshell.env("OMASHOT_BACKEND")}
 TestCase {name:"AnnotationPointerEvents";when:edit.previewReady
  function ready(){tryVerify(function(){return edit.previewReady},15000)}
  function require(ok,message){if(!ok){console.error("EVENT_FAILURE="+message);Qt.quit();throw new Error(message)}}
  function test_real_events(){
   edit.add({type:"arrow",x:50,y:50,x2:350,y2:250,width:5,color:"#ff0033"});edit.tool="select";edit.selectedIndex=-1;ready()
   var surface=edit.annotationSurface,sx=surface.sx,sy=surface.sy
   mouseDrag(surface,200*sx,150*sy,30*sx,40*sy,Qt.LeftButton,Qt.NoModifier,100)
   require(edit.selectedIndex===0,"Pointer selects arrow")
   require(Math.abs(edit.operations[0].x-80)<2&&Math.abs(edit.operations[0].y-90)<2,"Pointer moves arrow")
   ready();sx=surface.sx;sy=surface.sy
   mouseDrag(surface,230*sx,190*sy,0,-80*sy,Qt.LeftButton,Qt.NoModifier,100)
   require(Math.abs(edit.operations[0].cx-230)<3&&Math.abs(edit.operations[0].cy-30)<3,"Curve handle controls quadratic midpoint")
   edit.add({type:"rectangle",x:400,y:100,w:100,h:100,color:"#2455bb",width:4});edit.selectedIndex=1;ready();sx=surface.sx;sy=surface.sy
   mouseDrag(surface,500*sx,200*sy,100*sx,100*sy,Qt.LeftButton,Qt.NoModifier,100)
   require(Math.abs(edit.operations[1].w-200)<3&&Math.abs(edit.operations[1].h-200)<3,"Rectangle corner resizes existing annotation")
   edit.add({type:"text",x:100,y:300,text:"Old",size:24,color:"#111111"});edit.selectedIndex=-1;ready();sx=surface.sx;sy=surface.sy
   mouseDoubleClickSequence(surface,124*sx,317*sy,Qt.LeftButton,Qt.NoModifier,100)
   tryVerify(function(){return edit.textEditing&&edit.inlineEditor.activeFocus},3000)
   keyClick(Qt.Key_N);keyClick(Qt.Key_E);keyClick(Qt.Key_W);keyClick(Qt.Key_Return)
   require(!edit.textEditing&&edit.operations[2].text==="new","Double-click opens inline text and Enter commits keys")
   ready();keyClick(Qt.Key_Delete);require(edit.operations.length===2,"Delete removes selected object")
   keyClick(Qt.Key_Z,Qt.ControlModifier);require(edit.operations.length===3,"Keyboard undo restores deleted annotation")
   ready();edit.beginCrop();wait(100);sx=surface.sx;sy=surface.sy
   mouseDrag(surface,800*sx,500*sy,-100*sx,-100*sy,Qt.LeftButton,Qt.NoModifier,100)
   require(Math.abs(edit.cropBox.w-700)<3&&Math.abs(edit.cropBox.h-400)<3,"Actual crop handle updates draft bounds")
   edit.cancelActiveMode();require(!edit.cropEditing,"Crop mode cancels without flattening")
   edit.beginCrop();edit.cropBox={x:20,y:20,w:700,h:400};edit.applyCrop();ready();wait(100)
   require(edit.contentRect.sourceW===700&&edit.contentRect.sourceH===400,"Native crop updates current coordinate domain")
   edit.tool="filled";sx=surface.sx;sy=surface.sy
   mouseDrag(surface,10*sx,10*sy,40*sx,30*sy,Qt.LeftButton,Qt.NoModifier,100)
   require(edit.operations[edit.operations.length-1].type==="filled"&&Math.abs(edit.operations[edit.operations.length-1].x-10)<2,"Annotation pointer input remains usable after crop")
   edit.tool="rectangle";var count=edit.operations.length
   function at(x,y){return surface.mapToItem(edit,(x-surface.sourceX)*surface.sx,(y-surface.sourceY)*surface.sy)}
   function find(o){if(o&&o.acceptedModifiers===Qt.ControlModifier&&o.acceptedDevices!==undefined)return o;var d=o&&o.data||[];for(var i=0;i<d.length;i++){var f=find(d[i]);if(f)return f}return null}
   var wheel=find(edit);require(wheel&&(wheel.acceptedDevices&PointerDevice.TouchPad),"Ctrl+wheel accepts Qt Wayland's TouchPad-typed wl_pointer")
   var p=at(300,200),scale=surface.sx;mouseWheel(edit,p.x,p.y,0,360,Qt.NoButton,Qt.ControlModifier);wait(50)
   var q=at(300,200);require(Math.abs(surface.sx/scale-Math.pow(1.25,3))<.01,"Ctrl+wheel zooms");require(Math.abs(q.x-p.x)<1.5&&Math.abs(q.y-p.y)<1.5,"Ctrl+wheel keeps the pixel under the cursor")
   mouseDrag(edit,q.x,q.y,-100,-60,Qt.MiddleButton,Qt.NoModifier,50);wait(50);var r=at(300,200)
   require(Math.abs(r.x-q.x+100)<2&&Math.abs(r.y-q.y+60)<2,"Middle-drag pans the canvas with a drawing tool active");require(edit.operations.length===count,"Middle-drag does not draw")
   console.log("EVENTS_PASSED");Qt.quit()
  }
 }
 Timer {interval:45000;running:true;onTriggered:{console.error("EVENTS_TIMEOUT");Qt.quit()}}
} }''')
 result=subprocess.run(['qs','-p',str(harness)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=50)
 assert result.returncode==0 and 'EVENTS_PASSED' in result.stdout and not any(x in result.stdout for x in ['FAIL!','EVENT_FAILURE=','EVENTS_TIMEOUT','ReferenceError','TypeError','ERROR:']),result.stdout
print('PASS: actual mouse selection/move/curve/resize, inline text keyboard editing, delete/undo, crop handle input, Ctrl+wheel zoom and middle-drag pan')
