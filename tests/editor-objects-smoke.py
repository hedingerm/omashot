#!/usr/bin/env python3
"""Exercise production object selection, transforms, inline text, composition and crop."""
import json,os,pathlib,shutil,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
binary=root/'target/debug/omashot'
with tempfile.TemporaryDirectory(prefix='omashot-object-test-') as td:
 td=pathlib.Path(td);plugin=td/'plugin';shutil.copytree(root/'plugin',plugin)
 env=dict(os.environ,QT_QPA_PLATFORM='offscreen',XDG_CONFIG_HOME=str(td/'config'),XDG_DATA_HOME=str(td/'data'),OMASHOT_BACKEND=str(binary))
 source=td/'fixture.png';layer=td/'layer.png'
 subprocess.run(['magick','-size','800x500','xc:white',str(source)],check=True)
 subprocess.run(['magick','-size','80x50','xc:#168fce',str(layer)],check=True)
 env.update(OMASHOT_SOURCE=str(source),OMASHOT_LAYER=str(layer))
 harness=plugin/'ObjectSmoke.qml'
 harness.write_text('''import QtQuick
import Quickshell
ShellRoot { FloatingWindow {visible:true;implicitWidth:1100;implicitHeight:800
 Editor {id:edit;anchors.fill:parent;sourcePath:Quickshell.env("OMASHOT_SOURCE");backend:Quickshell.env("OMASHOT_BACKEND")
  onSaved:function(path){console.log("SAVED="+path);Qt.quit()}
  onError:function(message){console.error("TEST_ERROR="+message);Qt.quit()}
 }
 Timer {interval:100;repeat:true;running:true;property int phase:0
  function require(ok,message){if(!ok){console.error("TEST_ERROR="+message);Qt.quit();throw new Error(message)}}
  onTriggered:{
   if(edit.busy||!edit.previewReady)return
   if(phase===0){
    edit.add({type:"arrow",x:40,y:40,x2:320,y2:210,width:5,color:"#ff0033"});
    edit.add({type:"rectangle",x:400,y:100,w:100,h:80,width:4,color:"#0055cc"});
    edit.add({type:"text",x:100,y:300,text:"Before",size:24,color:"#111111"});phase=1;
   }else if(phase===1){
    edit.tool="rectangle";require(edit.drawToolHit(401,140)===1&&edit.drawToolHit(450,140)===-1,"Rectangle tool edits outlines, draws inside");edit.tool="text";require(edit.drawToolHit(110,310)===2,"Text tool edits text");edit.tool="arrow";require(edit.drawToolHit(401,140)===-1,"Other types draw");edit.tool="select";
    require(edit.selectAt(50,46)===0,"Arrow hit test");edit.beginGesture(0,40,40);edit.moveGesture(70,90);edit.endGesture();
    require(edit.operations[0].x===70&&edit.operations[0].y===90,"Arrow move");edit.undo();require(edit.operations[0].x===40,"Move undo");edit.redo();require(edit.operations[0].x===70,"Move redo");
    edit.beginGesture(0,0,0);edit.resizeGesture("curve",200,20);edit.endGesture();require(edit.operations[0].cx===190&&edit.operations[0].cy===-135,"Quadratic midpoint transform");
    edit.beginGesture(1,0,0);edit.resizeGesture("se",700,380);edit.endGesture();require(edit.operations[1].w===300&&edit.operations[1].h===280,"Rectangle resize");
    var spin=edit.sizeControl.contentItem;edit.selectedIndex=1;spin.text="1";spin.textEdited();spin.text="12";spin.textEdited();require(edit.operations[1].width===12&&edit.strokeWidth===12,"Typed stroke width applies without leaving the field");edit.undo();require(edit.operations[1].width===4,"Typed width is one undo step");edit.redo();
    edit.editText(100,300,2);edit.inlineEditor.text="After";edit.finishText(true);require(edit.operations[2].text==="After","Inline text replacement");var tb=edit.operations[2];require(tb.w>=40&&tb.w<=65&&tb.h>=14&&tb.h<=22,"Text box hugs the ink: "+tb.w+"x"+tb.h);edit.changeSelected("style","boxed");require(edit.operations[2].style==="boxed","Text style");
    edit.selectedIndex=1;edit.deleteSelected();require(edit.operations.length===2,"Delete selected");edit.undo();require(edit.operations.length===3,"Delete undo");
    edit.beginCrop();edit.updateCrop("se",600,400);require(edit.cropBox.w===600&&edit.operations.length===3,"Crop draft not applied");require(edit.cancelActiveMode()&&!edit.cropEditing,"Crop cancellation");
    edit.importLayer(Quickshell.env("OMASHOT_LAYER"));phase=2;
   }else if(phase===2){
    if(edit.operations.length!==4)return;
    console.log("IMPORTED_LAYER="+edit.operations[3].path);require(edit.operations[3].type==="image"&&edit.operations[3].y===500,"Dropped layer stacks below source");require(edit.renderedHeight===550,"Composited canvas expands");
    edit.beginCrop();edit.cropBox={x:-10,y:-10,w:850,h:580};edit.cropFill="#ffffff";edit.applyCrop();phase=3;
   }else if(phase===3){
    require(edit.renderedWidth===850&&edit.renderedHeight===580,"Crop expands canvas with fill");
    edit.add({type:"filled",x:10,y:10,w:20,h:20,color:"#1234de"});phase=4;
   }else if(phase===4){
    require(edit.selectAt(15,15)===5,"Post-crop annotation uses current canvas coordinates");
    require(edit.selectAt(120,320)===-1,"Pre-crop marks are not edited in the wrong coordinate domain");
    edit.undo();edit.undo();require(edit.editableStart===0&&edit.operations.length===4,"Undo restores pre-crop editable objects");edit.redo();edit.redo();require(edit.operations.length===6,"Redo restores crop plus subsequent mark");edit.render(false);phase=5;
   }
  }
 }
 Timer {interval:35000;running:true;onTriggered:{console.error("TEST_ERROR=Object test timeout");Qt.quit()}}
} }''')
 result=subprocess.run(['qs','-p',str(harness)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=40)
 assert result.returncode==0 and 'SAVED=' in result.stdout and not any(w in result.stdout for w in ['TEST_ERROR=','ReferenceError','TypeError','ERROR:']),result.stdout
 path=pathlib.Path(result.stdout.split('SAVED=',1)[1].splitlines()[0].strip())
 project=json.loads(subprocess.check_output([str(binary),'project',str(path)],env=env,text=True));assert [o['type'] for o in project['operations']]==['arrow','rectangle','text','image','crop','filled'],project
 assert project['operations'][2]['text']=='After'
 asset=pathlib.Path(project['operations'][3]['path']);assert asset.exists()
 imported=pathlib.Path(result.stdout.split('IMPORTED_LAYER=',1)[1].splitlines()[0].strip());assert asset!=imported
 subprocess.check_output([str(binary),'delete',str(imported)],env=env,text=True);assert asset.exists()
 pixel=subprocess.check_output(['magick',str(path),'-format','%[hex:p{15,15}]','info:'],text=True).strip();assert pixel.startswith('1234DE'),pixel
 rendered=td/'restored.png';subprocess.check_output([str(binary),'render',project['source'],json.dumps(project['operations']),str(rendered)],env=env,text=True);assert rendered.exists()
print('PASS: selection/move/resize/curve, inline text/style/delete undo, image composition, crop draft/cancel/expand and native saved project')
