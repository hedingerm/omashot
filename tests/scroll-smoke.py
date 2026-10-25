#!/usr/bin/env python3
"""Capture and stitch actual scrolled Wayland pixels in a temporary fixture app."""
import json, os, pathlib, random, shutil, subprocess, tempfile, time
root=pathlib.Path(__file__).resolve().parents[1]
binary=root/'target/release/omashot'
with tempfile.TemporaryDirectory(prefix='omashot-scroll-test-') as td:
    td=pathlib.Path(td); env=dict(os.environ,XDG_DATA_HOME=str(td/'data'),XDG_CONFIG_HOME=str(td/'config'))
    # Non-periodic pixels prevent a naive repeated-row match from passing.
    noise=td/'noise.ppm'; rng=random.Random(703)
    noise.write_bytes(b'P6\n900 2800\n255\n'+rng.randbytes(900*2800*3))
    image=td/'noise.png'; subprocess.run(['magick',str(noise),str(image)],check=True)
    env['OMASHOT_SCROLL_IMAGE']=str(image)
    app=td/'shell.qml'
    app.write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
 FloatingWindow {
  title: "OmaShot scrolling verification"; visible: true; fullscreen: true
  Flickable {
   id: scroll; anchors.fill: parent; contentWidth: width; contentHeight: image.height
   Image { id: image; width: scroll.width; height: width*2800/900; source: "file://"+Quickshell.env("OMASHOT_SCROLL_IMAGE") }
  }
 }
 IpcHandler { target: "scrollfixture"; function offset(y: int): void { scroll.contentY = y } }
}''')
    def ipc(y): return subprocess.run(['qs','ipc','-p',str(app),'call','scrollfixture','offset',str(y)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode
    def command(*args): return json.loads(subprocess.check_output([str(binary),*map(str,args)],env=env,text=True))
    with (td/'app.log').open('w') as log:
        shell=subprocess.Popen(['qs','-p',str(app)],env=env,stdout=log,stderr=log)
        try:
            deadline=time.monotonic()+10
            while ipc(0):
                assert shell.poll() is None,(td/'app.log').read_text()
                if time.monotonic()>deadline: raise AssertionError('fixture did not load')
                time.sleep(.1)
            time.sleep(.5)
            windows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],text=True))
            window=next(w for w in windows if w['title']=='OmaShot scrolling verification')
            x,y=window['at']; w,h=window['size']; w=min(500,w-80); h=min(400,h-80)
            geometry=f'{x+40},{y+40} {w}x{h}'
            session=command('scroll','start','--geometry',geometry)['session']
            frame=td/'data/omashot'/('.scroll-'+session+'.png')
            first=list(map(int,subprocess.check_output(['magick','identify','-format','%w %h',str(frame)],text=True).split()))
            assert ipc(100)==0; time.sleep(.3)
            appended=command('scroll','append',session)
            result=command('scroll','finish',session)
            expected=round(first[1]+100*first[1]/h)
            assert result['width']==first[0] and abs(result['height']-expected)<=2,(first,result,expected)
            assert pathlib.Path(result['path']).exists() and not frame.exists()
        finally:
            shell.terminate()
            try: shell.wait(timeout=5)
            except subprocess.TimeoutExpired: shell.kill(); shell.wait()
    logtext=(td/'app.log').read_text(); assert not any(x in logtext for x in ['ERROR','ReferenceError','TypeError']),logtext
print('PASS: actual scrolled Wayland viewport capture, overlap registration, append and final stitched dimensions')
