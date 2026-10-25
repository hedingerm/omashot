#!/usr/bin/env python3
"""Check every toolbar action remains reachable when a WM ignores size hints."""
import os,pathlib,shutil,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='omashot-narrow-test-') as td:
 td=pathlib.Path(td);plugin=td/'plugin';shutil.copytree(root/'plugin',plugin)
 source=td/'source.png';subprocess.run(['magick','-size','400x300','xc:#d7dae5',str(source)],check=True)
 env=dict(os.environ,QT_QPA_PLATFORM='offscreen',XDG_CONFIG_HOME=str(td/'config'),XDG_DATA_HOME=str(td/'data'),OMASHOT_BACKEND=str(root/'target/debug/omashot'),OMASHOT_SOURCE=str(source))
 harness=plugin/'NarrowSmoke.qml'
 harness.write_text('''import QtQuick
import Quickshell
import QtTest
ShellRoot { FloatingWindow {visible:true;implicitWidth:640;implicitHeight:740
 Editor {id:edit;anchors.fill:parent;sourcePath:Quickshell.env("OMASHOT_SOURCE");backend:Quickshell.env("OMASHOT_BACKEND")}
 TestCase {name:"NarrowToolbarLayout";when:edit.previewReady
  function require(ok,message){if(!ok){console.error("NARROW_FAILURE="+message);Qt.quit();throw new Error(message)}}
  function checkToolbar(strip,expectedOverflow){
   require(strip.visible,"Correct toolbar visible")
   require(strip.clip&&strip.contentWidth>=strip.width,"Toolbar clips a naturally sized row")
   if(expectedOverflow)require(strip.contentWidth>strip.width,"Overflow is horizontally scrollable")
   var row=strip.contentItem.children[0],lastRight=0,items=[]
   for(var i=0;i<row.children.length;i++){
    var child=row.children[i]
    if(!child.visible||child.width<1)continue
    require(child.x>=lastRight-.5,"No overlapping toolbar controls")
    lastRight=child.x+child.width;items.push(child)
   }
   require(items.length>3,"Toolbar contains all control groups")
   require(lastRight<=strip.contentWidth+1,"All controls fit the scrollable content")
   strip.contentX=strip.contentWidth-strip.width;wait(50)
   var last=items[items.length-1],p=last.mapToItem(edit,0,0)
   require(p.x>=0&&p.x+last.width<=edit.width+1,"Last action reachable after horizontal scroll")
   strip.contentX=0
  }
  function test_narrow_layout(){
   wait(120);require(edit.width===640,"Fixture is actually narrow")
   checkToolbar(edit.annotationToolbar,true)
   edit.tool="pixelate";wait(80);checkToolbar(edit.annotationToolbar,true)
   edit.tool="text";wait(80);checkToolbar(edit.annotationToolbar,true)
   edit.beginCrop();wait(100);checkToolbar(edit.cropToolbar,true)
   edit.cancelActiveMode();wait(80);checkToolbar(edit.annotationToolbar,true)
   console.log("NARROW_PASSED");Qt.quit()
  }
 }
 Timer {interval:15000;running:true;onTriggered:{console.error("NARROW_TIMEOUT");Qt.quit()}}
} }''')
 result=subprocess.run(['qs','-p',str(harness)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
 assert result.returncode==0 and 'NARROW_PASSED' in result.stdout and not any(x in result.stdout for x in ['NARROW_FAILURE=','NARROW_TIMEOUT','ReferenceError','TypeError','ERROR:']),result.stdout
print('PASS: 640px normal/text/concealment/crop toolbars have no overlaps and all actions scroll into view')
