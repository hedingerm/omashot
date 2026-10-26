#!/usr/bin/env python3
"""Register generated shortcuts in an isolated Lua compositor and read them through the bar widget."""
import json, os, pathlib, shutil, signal, subprocess, tempfile, time

root=pathlib.Path(__file__).resolve().parents[1];binary=root/'target/debug/omashot'
omarchy=pathlib.Path(os.environ.get('OMARCHY_PATH','/usr/share/omarchy'))
with tempfile.TemporaryDirectory(prefix='omashot-bindings-live-') as td:
    td=pathlib.Path(td);config=td/'config';(config/'hypr').mkdir(parents=True)
    user=config/'hypr/bindings.lua';user.write_text('-- isolated test bindings\n')
    lua=td/'hyprland.lua'
    lua.write_text('hl.monitor({output="",mode="800x600@60",position="0x0",scale=1})\n'
                   +f'dofile({json.dumps(str(omarchy/"default/hypr/helpers.lua"))})\n'
                   +f'dofile({json.dumps(str(user))})\n')
    env=dict(os.environ,XDG_CONFIG_HOME=str(config),XDG_DATA_HOME=str(td/'data'))
    with (td/'hyprland.log').open('w') as log:
        proc=subprocess.Popen(['Hyprland','-c',str(lua)],env=env,stdout=log,stderr=log,start_new_session=True)
        try:
            instance=None
            for _ in range(100):
                instances=json.loads(subprocess.check_output(['hyprctl','-j','instances'],text=True))
                instance=next((i for i in instances if i['pid']==proc.pid),None)
                if instance:break
                assert proc.poll() is None,(td/'hyprland.log').read_text()
                time.sleep(.1)
            assert instance,'Lua compositor did not start'
            env.update(WAYLAND_DISPLAY=instance['wl_socket'],HYPRLAND_INSTANCE_SIGNATURE=instance['instance'])
            def command(*args):
                return json.loads(subprocess.check_output([str(binary),*args],env=env,text=True))
            # Wait for the config manager, not just its IPC socket.
            for _ in range(50):
                probe=subprocess.run(['hyprctl','eval','return true'],env=env,capture_output=True,text=True)
                if 'true' in probe.stdout:break
                time.sleep(.1)
            wanted={'text':'SUPER + ALT + T','scroll':'SUPER + ALT + S','preferences':'SUPER + ALT + P'}
            applied=command('bindings','set',json.dumps(wanted))
            assert applied['reloaded'] and applied['missing']==[],applied
            assert applied['active']==wanted,applied
            actual=json.loads(subprocess.check_output(['hyprctl','-j','binds'],env=env,text=True))
            assert all(b['dispatcher']=='__lua' and b['arg'].isdigit() for b in actual),actual
            assert not command('bindings')['taken']
            # Load the real bar component with shell imports, without starting or changing the real shell.
            shell=td/'shell';shell.mkdir();shutil.copytree(root/'plugin',shell/'plugin')
            for name in ['Commons','Ui','services']:(shell/name).symlink_to(omarchy/'shell'/name,target_is_directory=True)
            (shell/'shell.qml').write_text('''import QtQuick
import Quickshell
import "plugin" as Plugin
ShellRoot {
 Plugin.Main {id:main}
 Timer {interval:200;running:true;onTriggered:main.run(["config"],"config")}
 Loader {id:widget;source:"plugin/BarWidget.qml";onLoaded:item.refreshHotkeys()}
 Timer {interval:100;repeat:true;running:true;property int tries:0;property int phase:0;onTriggered:{
   if(phase===0 && widget.item && widget.item.hotkeys.text==="SUPER + ALT + T" && main.shortcutInfo.hyprland){
     if(!widget.item.actions.some(a=>a.mode==="text") || widget.item.actions.some(a=>a.mode==="qr"))throw new Error("Recognition actions disagree")
     main.shortcutDraft=Object.assign({},main.shortcutDraft,{text:"SUPER + ALT + Y"});main.saveShortcuts();phase=1
   } else if(phase===1 && main.status==="Shortcuts applied" && main.shortcutInfo.active.text==="SUPER + ALT + Y"){
     widget.item.refreshHotkeys();phase=2
   } else if(phase===2 && widget.item.hotkeys.text==="SUPER + ALT + Y"){
     console.log("BAR_SHORTCUTS_OK");Qt.quit()
   } else if(++tries>80){console.error("BAR_SHORTCUTS_FAILED",main.status,JSON.stringify(main.shortcutInfo));Qt.quit()}
 }}
}''')
            ui=subprocess.run(['qs','-p',str(shell)],env=dict(env,QT_QPA_PLATFORM='wayland',OMASHOT_BACKEND=str(binary)),capture_output=True,text=True,timeout=15)
            assert ui.returncode==0 and 'BAR_SHORTCUTS_OK' in ui.stdout,ui.stdout+ui.stderr
            command('bindings','remove')
            assert command('bindings')['active']=={}
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid,signal.SIGTERM)
                try:proc.wait(timeout=5)
                except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
print('PASS: generated Lua shortcuts register in Hyprland, Preferences saves shortcuts, bar reads active callbacks, removal clears them')
