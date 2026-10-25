#!/usr/bin/env python3
"""Follow Omarchy theme switches live: same swap as omarchy-theme-set, animated, controls palette included."""
import os,pathlib,shutil,subprocess,tempfile,time
root=pathlib.Path(__file__).resolve().parents[1]
def theme(state,name,bg,fg,accent,mode):
 nxt=state/'next-theme';nxt.mkdir(parents=True)
 (nxt/'colors.toml').write_text(f'mode = "{mode}"\naccent = "{accent}"\nbackground = "{bg}"\nforeground = "{fg}"\nred = "#f38ba8"\n')
 shutil.rmtree(state/'theme',ignore_errors=True);nxt.rename(state/'theme');(state/'theme.name').write_text(name+'\n')
with tempfile.TemporaryDirectory(prefix='omashot-theme-test-') as td:
 td=pathlib.Path(td);plugin=td/'plugin';shutil.copytree(root/'plugin',plugin);state=td/'state';state.mkdir()
 theme(state,'dark','#1e1e2e','#cdd6f4','#89b4fa','dark')
 env=dict(os.environ,QT_QPA_PLATFORM='offscreen',XDG_CONFIG_HOME=str(td/'config'),XDG_DATA_HOME=str(td/'data'),OMASHOT_THEME_PATH=str(state))
 harness=plugin/'ThemeSmoke.qml'
 harness.write_text('''import QtQuick
import QtQuick.Controls
import Quickshell
ShellRoot { FloatingWindow {id:win;visible:true;implicitWidth:300;implicitHeight:200
 Item {id:host;anchors.fill:parent;palette:Theme.controls.palette
  IconButton {id:button;selected:true}
  Menu {id:menu;palette:Theme.controls.palette}
 }
 property var samples:[]
 property int settled:0
 function hex(c){return c.toString().toLowerCase()}
 function fail(m){console.error("THEME_FAILURE="+m);Qt.quit()}
 Timer {interval:200;running:true;onTriggered:{
  if(!Theme.ready||win.hex(Theme.background)!=="#1e1e2e"||win.hex(Theme.accent)!=="#89b4fa"||Theme.light)win.fail("initial theme loads synchronously: "+Theme.background)
  else if(win.hex(button.background.color)!=="#89b4fa"||win.hex(menu.palette.window)!==win.hex(Theme.panel))win.fail("controls bind to theme")
  else console.log("THEME_READY")
 }}
 Connections {target:Theme;function onBackgroundChanged(){win.samples=win.samples.concat([win.hex(Theme.background)])}}
 Timer {interval:100;repeat:true;running:win.samples.length>0;onTriggered:{
  if(win.hex(Theme.background)!=="#eff1f5"||++win.settled<3)return
  running=false
  if(win.samples.length<4)win.fail("switch animates through intermediate colors: "+win.samples.length)
  else if(win.hex(Theme.accent)!=="#1e66f5"||!Theme.light||win.hex(Theme.accentText)!=="#eff1f5")win.fail("light theme roles: "+Theme.accent+" "+Theme.accentText)
  else if(win.hex(button.background.color)!=="#1e66f5"||win.hex(host.palette.window)!==win.hex(Theme.panel)||win.hex(menu.palette.text)!=="#4c4f69"||win.hex(menu.palette.disabled.text)!==win.hex(Theme.textDisabled))win.fail("controls follow the switch: "+button.background.color+" "+host.palette.window+" "+Theme.panel+" "+menu.palette.text)
  else{console.log("THEME_PASSED");Qt.quit()}
 }}
 Timer {interval:15000;running:true;onTriggered:win.fail("timeout")}
} }''')
 proc=subprocess.Popen(['qs','-p',str(harness)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 out=[]
 try:
  for line in proc.stdout:
   out.append(line);print(line,end="",flush=True) if os.environ.get("THEME_DEBUG") else None
   if 'THEME_READY' in line:time.sleep(.3);theme(state,'light','#eff1f5','#4c4f69','#1e66f5','light')
  proc.wait(timeout=20)
 finally:
  if proc.poll() is None:proc.kill()
 log=''.join(out)
 assert 'THEME_PASSED' in log and not any(x in log for x in ['THEME_FAILURE=','ReferenceError','TypeError']),log
print('PASS: theme loads synchronously, follows an omarchy-style swap with an animated fade, light roles and controls palette')
