#!/usr/bin/env python3
"""Real Wayland/Quickshell + Rust round-trip. Uses isolated data and synthetic pixels."""
import json, os, pathlib, shutil, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / 'target/debug/omashot'
def call(cmd, env, **kw):
    return subprocess.check_output(list(map(str, cmd)), env=env, text=True, **kw).strip()
with tempfile.TemporaryDirectory(prefix='omashot-ui-test-') as temp:
    temp = pathlib.Path(temp)
    plugin = temp / 'plugin'
    shutil.copytree(ROOT / 'plugin', plugin)
    env = dict(os.environ, OMASHOT_BACKEND=str(BIN), XDG_DATA_HOME=str(temp / 'data'), XDG_CONFIG_HOME=str(temp / 'config'))
    fixture = temp / 'fixture.png'
    call(['magick','-size','800x480','xc:white','-font','/usr/share/fonts/liberation/LiberationSans-Regular.ttf','-fill','black','-pointsize','52','-annotate','+40+100','OMA SHOT 12345',fixture], env)
    env['OMASHOT_FIXTURE'] = str(fixture)
    def ipc(*args): return call(['qs','ipc','-p',plugin,'call','omashot',*args], env, stderr=subprocess.DEVNULL)
    def wait_for(predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                value = json.loads(ipc('status'))
                if predicate(value): return value
            except (subprocess.CalledProcessError,json.JSONDecodeError): pass
            time.sleep(.1)
        raise AssertionError('UI state did not converge')
    log = temp / 'ui.log'
    with log.open('w') as out:
        proc = subprocess.Popen(['qs','-p',str(plugin)],env=env,stdout=out,stderr=out)
        try:
            wait_for(lambda s: True)
            ipc('importImage',str(fixture))
            state = wait_for(lambda s: s['current'] and s['status']=='Done')
            imported = pathlib.Path(state['current']); assert imported.exists()
            ipc('annotate'); ipc('pin')
            wait_for(lambda s: s['opened'] and s['editing'] and s['pins']==1)
            ipc('capture','fullscreen')
            wait_for(lambda s: s['quickOpened'] and not s['opened'])
            captures = json.loads(call([BIN,'history'],env)); assert len(captures)==2
            ipc('dismiss')
        finally:
            proc.terminate()
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()
    text = log.read_text()
    assert not any(x in text for x in ['ERROR','ReferenceError','TypeError','failed to create variant']), text
    # Invoke the real editor's production add/undo/redo/render methods in a live window.
    harness = plugin / 'EditorSmoke.qml'
    harness.write_text('''import QtQuick
import Quickshell
ShellRoot {
    FloatingWindow {
        visible: true; implicitWidth: 1000; implicitHeight: 700
        Editor {
            id: edit; anchors.fill: parent
            sourcePath: Quickshell.env("OMASHOT_FIXTURE")
            backend: Quickshell.env("OMASHOT_BACKEND")
            onSaved: function(path) { console.log("EDITOR_SAVED=" + path); Qt.quit() }
            onError: function(message) { console.error("EDITOR_ERROR=" + message); Qt.quit() }
        }
        Timer { interval: 1000; running: true; onTriggered: {
            edit.add({type:"redact",x:20,y:20,w:40,h:40});
            edit.add({type:"arrow",x:100,y:200,x2:600,y2:300,color:"#ff0033",width:8});
            edit.undo(); edit.redo();
            edit.add({type:"text",x:100,y:350,text:"Round trip",size:40,color:"#0055ff"});
            edit.render(false);
        } }
    }
}''')
    result = subprocess.run(['qs','-p',str(harness)],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=25)
    assert result.returncode==0 and 'EDITOR_SAVED=' in result.stdout and 'EDITOR_ERROR=' not in result.stdout, result.stdout
    saved = pathlib.Path(result.stdout.split('EDITOR_SAVED=',1)[1].splitlines()[0].strip())
    assert saved.exists()
    project = json.loads(call([BIN,'project',saved],env)); assert len(project['operations'])==3 and pathlib.Path(project['source']).exists()
    exported = temp / 'export.png'
    call([BIN,'export',saved,exported],env)
    assert call(['magick',exported,'-format','%[pixel:p{30,30}]','info:'],env) in ['srgba(0,0,0,1)','srgb(0,0,0)']
    call([BIN,'copy',saved],env)
    copied = temp / 'clipboard.png'
    with copied.open('wb') as out: subprocess.run(['wl-paste','--type','image/png'],env=env,stdout=out,check=True)
    metric = call(['magick','compare','-metric','AE',exported,copied,'null:'],env,stderr=subprocess.STDOUT)
    assert float(metric.split()[0])==0, repr(metric)
    ocr = json.loads(call([BIN,'ocr',fixture],env)); assert '12345' in ocr['text'],ocr
    qr = temp / 'qr.png'; call(['qrencode','-s','8','-o',qr,'https://example.org/omashot-test'],env)
    decoded = json.loads(call([BIN,'qr',qr],env)); assert decoded['text']=='https://example.org/omashot-test',decoded
    # Combined recognition prefers a QR code, falls back to OCR and leaves the clipboard alone when both find nothing.
    both = json.loads(call([BIN,'recognize',qr],env)); assert both=={'kind':'qr','text':'https://example.org/omashot-test'},both
    both = json.loads(call([BIN,'recognize',fixture],env)); assert both['kind']=='text' and '12345' in both['text'],both
    blank = temp / 'blank.png'; call(['magick','-size','200x100','xc:white',blank],env)
    call(['wl-copy','omashot-keep'],env); assert json.loads(call([BIN,'recognize',blank],env))=={'kind':'none','text':''}
    assert call(['wl-paste','--no-newline'],env)=='omashot-keep'
    call([BIN,'delete',saved],env); assert not saved.exists() and not pathlib.Path(project['source']).exists()
print('PASS: live QML capture/quick access/editor/pin, project/export/delete, clipboard pixels, OCR, QR and combined recognition')
