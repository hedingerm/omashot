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
  picker.showCrosshair=false;picker.showMagnifier=false
  test.require(!picker.showCrosshair&&!picker.showMagnifier,"Capture aid preferences")
  picker.begin(x+50,y+50);picker.end()
  test.require(test.emitted===0&&!picker.hasSelection,"Click without drag does not capture")
  picker.begin(x+65,y+65);picker.update(x+140,y+120);picker.update(x+175,y+165)
  test.require(test.emitted===0&&picker.selectionWidth===110&&picker.selectionHeight===100,"Drag geometry before release")
  picker.end();test.require(test.emitted===1,"Release captures immediately")
  picker.finish();picker.end();test.require(test.emitted===1,"Single completion signal")
  console.log("SELECTED="+test.selectedGeometry);Qt.quit()
 }catch(e){console.error("TEST_ERROR="+e);Qt.quit()}}}
 Timer {interval:10000;running:true;onTriggered:{console.error("TEST_ERROR=Selector timeout");Qt.quit()}}
}''')
    result=subprocess.run(['qs','-p',str(harness)],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
    assert result.returncode==0 and 'SELECTED=' in result.stdout and not any(w in result.stdout for w in ['TEST_ERROR=','ReferenceError','TypeError','ERROR:']),result.stdout
    geometry=result.stdout.split('SELECTED=',1)[1].splitlines()[0].strip()
    expected=f"{int(snapshot['originX'])+65},{int(snapshot['originY'])+65} 110x100"
    assert geometry==expected,(geometry,expected)
    # A stale slurp selection must not survive a frozen selection for repeat-last-area.
    (temp/'data/omashot/.last-selection').write_text('0,0 50x40')
    captured=command('capture-frozen',raw,geometry)
    scale=snapshot['scale'];x=65;y=65
    assert captured['width']==math.ceil((x+110)*scale)-math.floor(x*scale),captured
    assert captured['height']==math.ceil((y+100)*scale)-math.floor(y*scale),captured
    assert not raw.exists(), 'Frozen screenshot must be removed after committing'
    repeated=command('capture','repeat')
    assert abs(repeated['width']-captured['width'])<=1 and abs(repeated['height']-captured['height'])<=1,(repeated,captured)
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
    assert len(command('history'))==2, 'Cancellation must not add a history capture'
print('PASS: live frozen selector, capture on release, coordinate mapping, physical crop and cancellation')
