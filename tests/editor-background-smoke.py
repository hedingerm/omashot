#!/usr/bin/env python3
"""Exercise the production background sidebar, previews and project restoration.
All application data is isolated. Optional --screenshot saves a rendered UI image.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'target/release/omashot'
parser = argparse.ArgumentParser()
parser.add_argument('--screenshot', type=Path)
args = parser.parse_args()

def run(command, env):
    return subprocess.check_output(list(map(str, command)), env=env, text=True).strip()

def dashboard_svg():
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="640" viewBox="0 0 1000 640">',
             '<rect width="1000" height="640" fill="#f4f6fb"/>',
             '<rect width="174" height="640" fill="#18223a"/>']
    def text(x, y, value, size=15, color='#66728c', weight='normal'):
        parts.append(f'<text x="{x}" y="{y}" font-family="DejaVu Sans" font-size="{size}" font-weight="{weight}" fill="{color}">{value}</text>')
    def rect(x, y, w, h, fill, radius=12):
        parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}"/>')
    rect(20, 24, 32, 32, '#8070eb', 9)
    text(31, 47, 'N', 20, '#ffffff', 'bold')
    text(65, 47, 'Northstar', 16, '#ffffff', 'bold')
    for y, label in [(118, 'Overview'), (164, 'Projects'), (210, 'Analytics'), (256, 'Team'), (302, 'Settings')]:
        if y == 118: rect(14, y - 28, 146, 40, '#324469', 7)
        text(31, y, label, 14, '#e0e6f7' if y == 118 else '#99a6c4')
    text(208, 54, 'Project overview', 26, '#202c45', 'bold')
    text(208, 83, 'A clear view of what your team is building.', 14)
    rect(818, 31, 145, 40, '#7362da', 8)
    text(846, 57, '+ New project', 13, '#ffffff')
    for x, title, count, detail, tone in [(208, 'Active projects', '24', '+4 this month', '#7467d7'),
            (468, 'Completed tasks', '186', '+18% from last week', '#35aa8a'),
            (728, 'Team velocity', '92%', 'Looking good', '#d99642')]:
        rect(x, 112, 234, 112, '#ffffff')
        text(x+20, 140, title, 13)
        text(x+20, 181, count, 30, '#25314d', 'bold')
        text(x+20, 205, detail, 11, tone)
    rect(208, 245, 754, 212, '#ffffff')
    text(230, 276, 'Activity this month', 15, '#26314a', 'bold')
    text(821, 276, 'Last 30 days', 11)
    for y in [310, 350, 390, 430]:
        parts.append(f'<path d="M230 {y}H940" stroke="#e9edf6"/>')
    parts.append('<path d="M230 414 L295 390 L360 400 L425 365 L490 370 L555 331 L620 350 L685 311 L750 326 L815 294 L880 308 L940 284" stroke="#8272e6" stroke-width="4" fill="none"/>')
    rect(208, 478, 754, 132, '#ffffff')
    text(230, 507, 'Recent projects', 15, '#26314a', 'bold')
    for y, label, owner, state in [(543, 'Website redesign', 'Design team', 'In progress'), (581, 'Mobile experience', 'Product team', 'On track')]:
        text(230, y, label, 13, '#38415c')
        text(547, y, owner, 12)
        rect(805, y-18, 122, 26, '#e8e4fc', 13)
        text(821, y, state, 11, '#7464c6')
    parts.append('</svg>')
    return ''.join(parts)

with tempfile.TemporaryDirectory(prefix='omashot-background-test-') as directory:
    temp = Path(directory)
    plugin = temp / 'plugin'
    shutil.copytree(ROOT / 'plugin', plugin)
    env = dict(os.environ, QT_QPA_PLATFORM='offscreen', OMASHOT_BACKEND=str(BIN),
               XDG_DATA_HOME=str(temp / 'data'), XDG_CONFIG_HOME=str(temp / 'config'))
    svg = temp / 'dashboard.svg'
    svg.write_text(dashboard_svg())
    source = temp / 'dashboard.png'
    run(['magick', svg, source], env)
    # Edits autosave over history captures only, so fixtures are imported like captures.
    def capture(path): return Path(json.loads(run([BIN, 'import', path], env))['path'])
    fixture, source = source, capture(source)
    wallpaper = temp / 'wallpaper.png'
    run(['magick', '-size', '600x400', 'gradient:#f79dd3-#376daa', wallpaper], env)
    screenshot = temp / 'editor.png'
    env.update(OMASHOT_SOURCE=str(source), OMASHOT_WALLPAPER=str(wallpaper), OMASHOT_SCREENSHOT=str(screenshot))
    harness = plugin / 'BackgroundSmoke.qml'
    harness.write_text('''import QtQuick
import Quickshell
ShellRoot {
    FloatingWindow {
        implicitWidth: 1100; implicitHeight: 800; visible: true
        Editor {
            id: edit; anchors.fill: parent
            sourcePath: Quickshell.env("OMASHOT_SOURCE")
            backend: Quickshell.env("OMASHOT_BACKEND")
            onSaved: function(path) { console.log("SAVED=" + path); Qt.quit() }
            onError: function(message) { console.error("TEST_ERROR=" + message); Qt.quit() }
        }
        Timer {
            id: steps; interval: 60; running: true; repeat: true
            property int phase: 0
            function require(condition,message) { if(!condition) { console.error("TEST_ERROR="+message);Qt.quit();throw new Error(message) } }
            onTriggered: {
                if(edit.busy || !edit.previewReady) return
                var panel=edit.backgroundControl
                if(phase===0){
                    panel.selectGradient(5);panel.update("padding",96);panel.update("inset",12);panel.update("radius",24);panel.update("shadow_strength",.5)
                    phase=1
                }else if(phase===1){
                    require(edit.contentRect.x===108 && edit.contentRect.y===108,"Background content mapping")
                    require(edit.renderedWidth===1216 && edit.renderedHeight===856,"Background dimensions")
                    edit.undo();require(edit.operations.length===0,"Coalesced background undo")
                    edit.redo();require(edit.backgroundOperation().padding===96,"Background redo")
                    edit.add({type:"arrow",x:360,y:400,x2:700,y2:295,color:"#ef5a78",width:6})
                    phase=2
                }else if(phase===2){
                    require(edit.operations[0].type==="arrow" && edit.operations[1].type==="background","Background stays after annotations")
                    panel.saveStyle("Documentation style")
                    require(edit.localPresets.length===1,"Saved background preset")
                    console.log("PRESETS="+JSON.stringify(edit.localPresets))
                    panel.run(["wallpaper","import",Quickshell.env("OMASHOT_WALLPAPER")],"import")
                    phase=3
                }else if(phase===3 && panel.settings.mode==="wallpaper"){
                    require(panel.settings.image_path!==Quickshell.env("OMASHOT_WALLPAPER"),"Wallpaper copied to durable storage")
                    panel.update("blur",24);phase=4
                }else if(phase===4){
                    require(edit.backgroundOperation().mode==="wallpaper" && edit.backgroundOperation().blur===24,"Live wallpaper blur")
                    panel.applyStyle(edit.localPresets[0]);phase=5
                }else if(phase===5){
                    require(panel.settings.mode==="gradient" && panel.settings.padding===96,"Preset restores geometry")
                    edit.zoom=1.25;require(edit.zoom===1.25,"Zoom control");edit.zoom=0
                    phase=6
                    edit.grabToImage(function(image){image.saveToFile(Quickshell.env("OMASHOT_SCREENSHOT"));edit.render(false)})
                }
            }
        }
        Timer { interval:45000;running:true;onTriggered:{console.error("TEST_ERROR=Background preview timeout");Qt.quit()} }
    }
}''')
    result = subprocess.run(['qs', '-p', harness], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=50)
    assert result.returncode == 0 and 'TEST_ERROR=' not in result.stdout and 'SAVED=' in result.stdout, result.stdout
    assert not any(word in result.stdout for word in ['ReferenceError', 'TypeError', 'ERROR:']), result.stdout
    saved = Path(result.stdout.split('SAVED=', 1)[1].splitlines()[0].strip())
    assert saved == source, saved
    project = json.loads(run([BIN, 'project', saved], env))
    assert [op['type'] for op in project['operations']] == ['arrow', 'background'], project
    assert project['operations'][1]['padding'] == 96
    assert json.loads(run([BIN, 'wallpaper', 'list'], env))[0]['path'] != str(wallpaper)
    presets = json.loads(result.stdout.split('PRESETS=', 1)[1].splitlines()[0])
    config = json.loads(run([BIN, 'config', json.dumps({'background_presets': presets})], env))
    assert config['background_presets'][0]['name'] == 'Documentation style'
    if args.screenshot:
        args.screenshot.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(screenshot, args.screenshot)
    # Start a fresh editor instance and verify the saved source/ops project restores.
    env['OMASHOT_SOURCE'] = str(saved)
    harness.write_text('''import QtQuick
import Quickshell
ShellRoot { FloatingWindow { implicitWidth:1100;implicitHeight:800;visible:true
    Editor { id:edit;anchors.fill:parent;sourcePath:Quickshell.env("OMASHOT_SOURCE");backend:Quickshell.env("OMASHOT_BACKEND") }
    Timer { interval:60;repeat:true;running:true;onTriggered:{
        if(edit.busy || !edit.previewReady)return
        if(edit.operations.length!==2 || edit.basePath===edit.sourcePath || edit.backgroundControl.settings.padding!==96 || edit.contentRect.x!==108){console.error("TEST_ERROR=Project restoration mismatch");Qt.quit();return}
        edit.undo();if(edit.operations.length!==1){console.error("TEST_ERROR=Restored undo mismatch");Qt.quit();return}
        console.log("RESTORED");Qt.quit()
    } }
    Timer { interval:20000;running:true;onTriggered:{console.error("TEST_ERROR=Restore timeout");Qt.quit()} }
} }''')
    restored = subprocess.run(['qs', '-p', harness], env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=25)
    assert restored.returncode == 0 and 'RESTORED' in restored.stdout and 'TEST_ERROR=' not in restored.stdout, restored.stdout
    # Last-used tool options and background come back on the next fresh capture; a vanished wallpaper is skipped.
    second = temp / 'second.png'
    run(['magick', '-size', '400x300', 'xc:#dde3f0', second], env)
    # Leaving a capture autosaves it, so each phase opens a fresh one.
    env.update(OMASHOT_SOURCE=str(capture(fixture)), OMASHOT_SECOND=str(capture(second)), OMASHOT_THIRD=str(capture(fixture)))
    harness.write_text('''import QtQuick
import Quickshell
ShellRoot { FloatingWindow { implicitWidth:1100;implicitHeight:800;visible:true
    Editor { id:edit;anchors.fill:parent;sourcePath:Quickshell.env("OMASHOT_SOURCE");backend:Quickshell.env("OMASHOT_BACKEND")
        property var used:null
        onSettingsUsed:function(s){used=s} }
    Timer { interval:60;repeat:true;running:true;property int phase:0
        function require(ok,message){if(!ok){console.error("TEST_ERROR="+message);Qt.quit();throw new Error(message)}}
        onTriggered:{
        if(edit.busy || !edit.previewReady)return
        if(phase===0){edit.lastTool="arrow";edit.ink="#22aa44";edit.strokeWidth=9;edit.textStyle="boxed";edit.redactionMode="blur";edit.cropRatio="16:9";edit.sidebarVisible=false
            edit.backgroundControl.selectGradient(3);edit.backgroundControl.update("padding",40);phase=1}
        else if(phase===1 && edit.used && edit.used.background && edit.used.background.padding===40){
            require(edit.used.tool==="arrow" && edit.used.ink==="#22aa44" && edit.used.stroke_width===9,"Settings reported")
            edit.savedSettings=edit.used;edit.ink="#ff657a";edit.strokeWidth=4;edit.tool="select";edit.sidebarVisible=true
            edit.sourcePath=Quickshell.env("OMASHOT_SECOND");phase=2}
        else if(phase===2){
            require(edit.tool==="arrow" && edit.ink==="#22aa44" && edit.strokeWidth===9 && edit.textStyle==="boxed" && edit.redactionMode==="blur" && edit.cropRatio==="16:9" && !edit.sidebarVisible,"Tool options restored")
            var bg=edit.backgroundOperation()
            require(edit.operations.length===1 && bg && bg.preset===3 && bg.padding===40 && edit.backgroundControl.settings.padding===40,"Background restored")
            require(edit.contentRect.x===40,"Restored background renders");edit.undo();require(!edit.operations.length,"Restored background undoes")
            var gone=Object.assign({},edit.savedSettings);gone.background={type:"background",mode:"wallpaper",image_path:"/nonexistent/wallpaper-1.png"}
            edit.savedSettings=gone;edit.sourcePath=Quickshell.env("OMASHOT_THIRD");phase=3}
        else if(phase===3){require(!edit.operations.length,"Missing wallpaper skipped");console.log("REMEMBERED");Qt.quit()}
    } }
    Timer { interval:30000;running:true;onTriggered:{console.error("TEST_ERROR=Remember timeout");Qt.quit()} }
} }''')
    remembered = subprocess.run(['qs', '-p', harness], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=35)
    assert remembered.returncode == 0 and 'REMEMBERED' in remembered.stdout and 'TEST_ERROR=' not in remembered.stdout, remembered.stdout
print('PASS: live gradient/padding/inset/radius/shadow, coalesced undo/redo, wallpaper import+blur, presets, zoom, save, editable project restore and remembered editor settings')
