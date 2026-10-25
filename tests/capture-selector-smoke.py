#!/usr/bin/env python3
"""Real Wayland frozen-region selector + backend crop/cancellation; isolated data."""
import json, math, os
from pathlib import Path
import shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
BIN=ROOT/'target/release/omashot'
with tempfile.TemporaryDirectory(prefix='omashot-selector-test-') as directory:
    temp=Path(directory);plugin=temp/'plugin'
    plugin.mkdir()
    for name in ['CaptureSelector.qml','Icon.qml','IconButton.qml','Theme.qml','qmldir']:
        shutil.copyfile(ROOT/'plugin'/name,plugin/name)
    env=dict(os.environ,OMASHOT_BACKEND=str(BIN),XDG_DATA_HOME=str(temp/'data'),XDG_CONFIG_HOME=str(temp/'config'))
    def command(*args):
        return json.loads(subprocess.check_output([str(BIN),*map(str,args)],env=env,text=True))
    snapshot=command('snapshot')
    raw=Path(snapshot['path']);assert raw.is_file()
    env['OMASHOT_SNAPSHOT']=json.dumps(snapshot)
    harness=plugin/'shell.qml'
    harness.write_text('''import QtQuick
import Quickshell
ShellRoot {
 id:test
 property int emitted:0
 property string selectedGeometry:""
 function require(value,message){if(!value)throw new Error(message)}
 CaptureSelector {
  id:picker;snapshot:JSON.parse(Quickshell.env("OMASHOT_SNAPSHOT"));opened:true
  onSelected:function(geometry){test.emitted++;test.selectedGeometry=geometry;opened=false}
 }
 Timer {interval:800;running:true;onTriggered:{try{
  let x=picker.originX,y=picker.originY
  picker.begin(x+40,y+40);picker.update(x+140,y+120);picker.end()
  test.require(picker.hasSelection&&picker.selectionWidth===100&&picker.selectionHeight===80,"Initial region geometry")
  picker.resizeBegin("se",x+140,y+120);picker.update(x+150,y+140);picker.end()
  test.require(picker.selectionWidth===110&&picker.selectionHeight===100,"Southeast resize")
  picker.begin(x+70,y+70);picker.update(x+85,y+95);picker.end()
  test.require(picker.selectionX===x+55&&picker.selectionY===y+65,"Region movement")
  let e={key:Qt.Key_Right,modifiers:Qt.ShiftModifier,accepted:false};picker.key(e)
  test.require(e.accepted&&picker.selectionX===x+65,"Keyboard precision movement")
  picker.showCrosshair=false;picker.showMagnifier=false
  test.require(!picker.showCrosshair&&!picker.showMagnifier,"Capture aid preferences")
  picker.finish();picker.finish();test.require(test.emitted===1,"Single completion signal")
  console.log("SELECTED="+test.selectedGeometry);Qt.quit()
 }catch(e){console.error("TEST_ERROR="+e);Qt.quit()}}}
 Timer {interval:10000;running:true;onTriggered:{console.error("TEST_ERROR=Selector timeout");Qt.quit()}}
}''')
    result=subprocess.run(['qs','-p',str(harness)],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
    assert result.returncode==0 and 'SELECTED=' in result.stdout and not any(w in result.stdout for w in ['TEST_ERROR=','ReferenceError','TypeError','ERROR:']),result.stdout
    geometry=result.stdout.split('SELECTED=',1)[1].splitlines()[0].strip()
    expected=f"{int(snapshot['originX'])+65},{int(snapshot['originY'])+65} 110x100"
    assert geometry==expected,(geometry,expected)
    captured=command('capture-frozen',raw,geometry)
    scale=snapshot['scale'];x=65;y=65
    assert captured['width']==math.ceil((x+110)*scale)-math.floor(x*scale),captured
    assert captured['height']==math.ceil((y+100)*scale)-math.floor(y*scale),captured
    assert not raw.exists(), 'Frozen screenshot must be removed after committing'
    # Cancellation emits exactly once, with Escape accepted, and removes only the raw snapshot.
    cancelled=command('snapshot');env['OMASHOT_SNAPSHOT']=json.dumps(cancelled)
    harness.write_text('''import QtQuick
import Quickshell
ShellRoot {
 property int emissions:0
 CaptureSelector {id:picker;snapshot:JSON.parse(Quickshell.env("OMASHOT_SNAPSHOT"));opened:true;onCancelled:emissions++}
 Timer {interval:500;running:true;onTriggered:{let e={key:Qt.Key_Escape,modifiers:0,accepted:false};picker.key(e);picker.reject();if(!e.accepted||emissions!==1)console.error("TEST_ERROR=Cancel event");else console.log("CANCELLED");Qt.quit()}}
}''')
    result=subprocess.run(['qs','-p',str(harness)],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
    assert result.returncode==0 and 'CANCELLED' in result.stdout and not any(w in result.stdout for w in ['TEST_ERROR=','ReferenceError','TypeError','ERROR:']),result.stdout
    command('snapshot-cancel',cancelled['path']);assert not Path(cancelled['path']).exists()
    assert len(command('history'))==1, 'Cancellation must not add a history capture'
print('PASS: live frozen selector, drag/move/resize, coordinate mapping, keyboard aids, physical crop and cancellation')
