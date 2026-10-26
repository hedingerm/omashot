#!/usr/bin/env python3
"""Production capture UI flows with a real Wayland fixture and isolated data.
Exercises independent quick previews, capture actions, frozen OCR and live scroll sampling.
"""
import json, os, pathlib, random, shutil, subprocess, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
BIN=ROOT/'target/release/omashot'
with tempfile.TemporaryDirectory(prefix='omashot-capture-flow-') as td:
    td=pathlib.Path(td);plugin=td/'plugin';shutil.copytree(ROOT/'plugin',plugin)
    env=dict(os.environ,OMASHOT_BACKEND=str(BIN),XDG_CONFIG_HOME=str(td/'config'),XDG_DATA_HOME=str(td/'data'))
    failure=td/'recognition-failure'
    wrapper=td/'backend'
    message=json.dumps({'error':'Recognition failed sentinel'})
    wrapper.write_text('#!/usr/bin/env python3\nimport os,pathlib,sys\n'
        +f'if sys.argv[1:2]==["recognize"] and pathlib.Path({str(failure)!r}).exists(): print({message!r});sys.exit(1)\n'
        +f'os.execv({str(BIN)!r},[{str(BIN)!r},*sys.argv[1:]])\n')
    wrapper.chmod(0o755);env['OMASHOT_BACKEND']=str(wrapper)
    exports=td/'exports';exports.mkdir()
    def backend(*args):return json.loads(subprocess.check_output([str(BIN),*map(str,args)],env=env,text=True))
    backend('config',json.dumps({'retention_days':0,'show_overlay':True,'copy_after_capture':True,'save_after_capture':True,'pin_after_capture':True,'export_directory':str(exports),'overlay_size':160}))
    noise=td/'noise.ppm';rng=random.Random(772);noise.write_bytes(b'P6\n900 2800\n255\n'+rng.randbytes(900*2800*3))
    scene=td/'noise.png';subprocess.run(['magick',str(noise),str(scene)],check=True)
    env['CAPTURE_FLOW_IMAGE']=str(scene)
    harness=plugin/'CaptureFlow.qml'
    harness.write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
 id:tester
 property var pendingPin:null
 property string pinPath:""
 Timer{id:pinGrabTimer;interval:250;onTriggered:tester.pendingPin.contentItem.children[0].grabToImage(function(image){image.saveToFile(tester.pinPath)})}
 Main{id:app}
 FloatingWindow {
  id:fixture;title:"OmaShot capture flow fixture";visible:true;fullscreen:true
  Rectangle{anchors.fill:parent;color:"white"}
  Text{id:words;x:40;y:70;text:"CAPTURE TEXT 12345";font.pixelSize:48;color:"black"}
  Flickable{id:scroll;anchors.fill:parent;contentWidth:width;contentHeight:picture.height;visible:false
   Image{id:picture;width:scroll.width;height:width*2800/900;source:"file://"+Quickshell.env("CAPTURE_FLOW_IMAGE")}
  }
 }
 IpcHandler {
  target:"captureverify"
  function capture(mode:string):void{app.capture(mode)}
  function select(geometry:string):void{app.finishFrozenSelection(geometry)}
  function cancelSelection():void{app.cancelFrozenSelection()}
  function scrolling(geometry:string):void{scroll.visible=true;words.visible=false;app.beginScrolling(geometry)}
  function sample():void{app.startScrollSampling()}
  function offset(value:int):void{scroll.contentY=value}
  function finish():void{app.finishScrolling()}
  function cancelScroll():void{app.cancelScrolling()}
  function reloadPreferences():void{app.run(["config"],"config-load")}
  function dismissQuick(id:int):void{app.dismissQuick(id)}
  function restore(path:string,w:int,h:int):void{app.restoreQuickCapture({path:path,width:w,height:h})}
  function probePins(path:string):string {
   for(let i=0;i<app.data.length;i++){
    let child=app.data[i];if(!child || !("instances" in child) || child.instances.length<2)continue;
    let a=child.instances[0],b=child.instances[1];if(!("clickThrough" in a))continue;
    a.implicitWidth=240;a.offsetX=-30;a.offsetY=12;a.imageOpacity=0.6;a.clickThrough=true;
    app.unlockPins();
    tester.pendingPin=a;tester.pinPath=path;pinGrabTimer.start()
    return JSON.stringify({width:a.implicitWidth,otherWidth:b.implicitWidth,opacity:a.imageOpacity,clickThrough:a.clickThrough,visible:a.visible,cw:a.contentItem.width,ch:a.contentItem.height})
   }
   return "{}"
  }
 }
}''')
    def ipc(target,method,*args):return subprocess.check_output(['qs','ipc','-p',str(harness),'call',target,method,*map(str,args)],env=env,text=True,stderr=subprocess.DEVNULL).strip()
    def status():return json.loads(ipc('omashot','status'))
    def wait(condition,seconds=15):
        end=time.monotonic()+seconds;last=None
        while time.monotonic()<end:
            try:
                last=status()
                if condition(last):return last
            except (subprocess.CalledProcessError,json.JSONDecodeError):pass
            if shell.poll() is not None:raise AssertionError((td/'ui.log').read_text())
            time.sleep(.1)
        raise AssertionError(('State did not converge',last,(td/'ui.log').read_text()))
    with (td/'ui.log').open('w') as log:
        shell=subprocess.Popen(['qs','-p',str(harness)],env=env,stdout=log,stderr=log)
        try:
            wait(lambda s:True);time.sleep(.5)
            ipc('captureverify','capture','fullscreen')
            one=wait(lambda s:s['quickCount']==1 and s['pins']==1 and len(list(exports.glob('*.png')))==1)
            ipc('captureverify','capture','fullscreen')
            two=wait(lambda s:s['quickCount']==2 and s['pins']==2 and len(list(exports.glob('*.png')))==2)
            assert one['current']!=two['current']
            pin_image=td/'pin.png';pin_value=ipc('captureverify','probePins',pin_image)
            assert pin_value,(td/'ui.log').read_text()
            pin_state=json.loads(pin_value)
            assert pin_state['width']==240 and pin_state['otherWidth']==360 and pin_state['opacity']==0.6 and not pin_state['clickThrough'] and pin_state['visible'],pin_state
            end=time.monotonic()+5
            while not pin_image.exists() and time.monotonic()<end:time.sleep(.1)
            assert pin_image.exists(),(pin_state,(td/'ui.log').read_text())
            alpha=subprocess.check_output(['magick',str(pin_image),'-format','%[fx:p{0,0}.a] %[fx:p{100,50}.a]','info:'],text=True).strip().split()
            # The corner is transparent only with rounded corners (Theme.corners / Hyprland rounding); square pins draw their border there.
            assert float(alpha[0])<1 and 0.5<float(alpha[1])<0.7,alpha
            clipboard=td/'clipboard.png'
            with clipboard.open('wb') as out:subprocess.run(['wl-paste','--type','image/png'],env=env,stdout=out,check=True)
            compared=subprocess.run(['magick','compare','-metric','AE',two['current'],str(clipboard),'null:'],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            assert compared.returncode==0,compared.stdout
            ipc('omashot','hideOverlays');wait(lambda s:s['quickCollapsed'])
            ipc('omashot','restoreOverlay');wait(lambda s:not s['quickCollapsed'] and s['quickCount']==2)
            ipc('captureverify','dismissQuick',2);wait(lambda s:s['quickCount']==1)
            history=backend('history');assert len(history)==2
            restored=next(c for c in history if c['path']==two['current'])
            ipc('captureverify','restore',restored['path'],restored['width'],restored['height']);wait(lambda s:s['quickCount']==2 and not s['opened'])
            ipc('captureverify','dismissQuick',3);wait(lambda s:s['quickCount']==1)
            # Direct recognition obtains a frozen screen, crops its region, falls back to OCR without a QR code, copies text and discards only its temporary capture.
            ipc('captureverify','capture','text');wait(lambda s:s['selecting'])
            clients=json.loads(subprocess.check_output(['hyprctl','-j','clients'],text=True));window=next(w for w in clients if w['title']=='OmaShot capture flow fixture')
            x,y=window['at'];w,h=window['size'];text_geometry=f'{x+20},{y+40} {min(750,w-40)}x160'
            ipc('captureverify','select',text_geometry)
            wait(lambda s:not s['selecting'] and not s['opened'] and s['status']=='Done' and len(backend('history'))==2)
            recognized=subprocess.check_output(['wl-paste','--no-newline'],env=env,text=True);assert '12345' in recognized,recognized
            assert not list((td/'data/omashot').glob('.frozen-*.png'))
            ipc('captureverify','capture','region');wait(lambda s:s['selecting']);ipc('captureverify','cancelSelection')
            wait(lambda s:not s['selecting'] and s['status']=='Done');time.sleep(.3)
            assert not list((td/'data/omashot').glob('.frozen-*.png'))
            # Failed recognition discards only its temporary capture and keeps the error after cleanup.
            failure.touch();ipc('captureverify','capture','text');wait(lambda s:s['selecting'])
            ipc('captureverify','select',text_geometry)
            wait(lambda s:s['opened'] and s['status']=='Recognition failed sentinel' and len(backend('history'))==2)
            time.sleep(.3);assert status()['status']=='Recognition failed sentinel',status()
            assert not list((td/'data/omashot').glob('.frozen-*.png'))
            failure.unlink();ipc('omashot','dismiss')
            # Continuous capture samples without reopening Main or requiring Add frame clicks.
            geometry=f'{x+40},{y+40} {min(500,w-80)}x{min(400,h-80)}'
            ipc('captureverify','scrolling','');wait(lambda s:s['selecting']);ipc('captureverify','select',geometry);wait(lambda s:s['scrollActive'])
            ipc('captureverify','sample');initial=wait(lambda s:s['scrollPolling'] and s['scrollPreviewReady'] and s['scrollHeight']>0)
            assert not initial['opened']
            ipc('captureverify','offset',100)
            grown=wait(lambda s:s['scrollHeight']>initial['scrollHeight'] and s['scrollPreviewReady'])
            assert not grown['opened']
            ipc('captureverify','offset',180)
            ipc('captureverify','finish');finished=wait(lambda s:not s['scrollActive'] and s['quickCount']==2 and s['status']=='Done')
            assert finished['scrollHeight']>grown['scrollHeight'],(grown,finished)
            assert len(backend('history'))==3
            assert not list((td/'data/omashot').glob('.scroll-*.json'))
            # Cancel a second in-place session without committing a capture.
            ipc('captureverify','scrolling',geometry);wait(lambda s:s['scrollActive']);ipc('captureverify','cancelScroll');wait(lambda s:not s['scrollActive'])
            assert len(backend('history'))==3
        finally:
            shell.terminate()
            try:shell.wait(timeout=5)
            except subprocess.TimeoutExpired:shell.kill();shell.wait()
    logs=(td/'ui.log').read_text()
    assert not any(word in logs for word in ['ERROR','ReferenceError','TypeError','Cannot open','failed to create variant']),logs
print('PASS: stacked quick previews/individual dismissal/collapse restore, post-capture copy/export/pin, frozen OCR/cancel, continuous scrolling preview/finish/cancel')
