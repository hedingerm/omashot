#!/usr/bin/env python3
"""Live Wayland: plugin loaded like omarchy-shell (Loader from another root), editor open, theme swap fades without jank.
Runs twice: a plain host (theme.name drives updates) and a host providing qs.Commons like omarchy-shell
(OmaShot must ignore theme.name and fade together with the shell palette)."""
import os,pathlib,shutil,subprocess,tempfile,time
root=pathlib.Path(__file__).resolve().parents[1]
def theme(state,name):
 nxt=state/'next-theme';nxt.mkdir(parents=True)
 shutil.copyfile(pathlib.Path('/usr/share/omarchy/themes')/name/'colors.toml',nxt/'colors.toml')
 shutil.rmtree(state/'theme',ignore_errors=True);nxt.rename(state/'theme');(state/'theme.name').write_text(name+'\n')
def run(shell_mode):
 with tempfile.TemporaryDirectory(prefix='omashot-theme-live-') as td:
  td=pathlib.Path(td);plugin=td/'plugin';shutil.copytree(root/'plugin',plugin);state=td/'state';state.mkdir();host=td/'host';host.mkdir()
  theme(state,'tokyo-night')
  # The host root can't see plugin singletons (neither can omarchy-shell); a probe in the plugin dir exposes Theme.
  (plugin/'ThemeProbe.qml').write_text('import QtQuick\nItem { readonly property QtObject theme: Theme }\n')
  if shell_mode:
   (host/'Commons').mkdir()
   (host/'Commons/qmldir').write_text('module qs.Commons\nsingleton Color 1.0 Color.qml\n')
   (host/'Commons/Color.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property color background: "#1a1b26"; property color foreground: "#a9b1d6"; property color accent: "#7aa2f7"; property color urgent: "#f7768e" }\n')
  sample=td/'sample.png';subprocess.run(['magick','-size','900x560','gradient:#4a6cf7-#c04af7',str(sample)],check=True)
  env=dict(os.environ,XDG_CONFIG_HOME=str(td/'config'),XDG_DATA_HOME=str(td/'data'),OMASHOT_THEME_PATH=str(state),OMASHOT_BACKEND=str(root/'target/debug/omashot'),OMASHOT_SAMPLE=str(sample))
  # In shell mode the host applies the palette 600 ms after theme.name changes, like omarchy-shell's applyTheme IPC.
  apply='Commons.Color.background="#eff1f5";Commons.Color.foreground="#4c4f69";Commons.Color.accent="#1e66f5"' if shell_mode else ''
  (host/'shell.qml').write_text('''import QtQuick
import Quickshell
'''+('import qs.Commons as Commons\n' if shell_mode else '')+'''ShellRoot {
 id:shell
 property var gaps:[]
 property var lum:[]
 property real last:0
 property real start:0
 property real end:0
 property real applied:0
 function l(c){return 0.2126*c.r+0.7152*c.g+0.0722*c.b}
 function fail(m){console.error("LIVE_FAILURE="+m);Qt.quit()}
 Loader {id:probe;source:"file://'''+str(plugin)+'''/ThemeProbe.qml"}
 readonly property QtObject theme: probe.item?probe.item.theme:null
 Loader {id:plugin;source:"file://'''+str(plugin)+'''/Main.qml";onLoaded:{item.open("{}");item.run(["import",Quickshell.env("OMASHOT_SAMPLE")],"import")}}
 Timer {interval:300;repeat:true;running:plugin.status===Loader.Ready;onTriggered:{
  if(!plugin.item.current)return
  running=false;plugin.item.beginEditing();ready.start()
 }}
 Timer {id:ready;interval:2500;onTriggered:{
  if(!plugin.item.editing||!shell.theme.ready||shell.theme.background.toString()!=="#1a1b26")shell.fail("editor open with initial theme")
  else{console.log("LIVE_READY");if('''+('true' if shell_mode else 'false')+''')applyTimer.start()}
 }}
 Timer {id:applyTimer;interval:900;onTriggered:{
  if(shell.start)shell.fail("theme.name alone must not repaint inside omarchy-shell")
  else{shell.applied=Date.now();'''+apply+'''}
 }}
 Connections {target:shell.theme;function onBackgroundChanged(){if(!shell.start)shell.start=Date.now();shell.lum=shell.lum.concat([shell.l(shell.theme.background)]);if(shell.theme.background.toString()==="#eff1f5"&&!shell.end){shell.end=Date.now();done.start()}}}
 FrameAnimation {running:shell.start>0&&!shell.end;onTriggered:{var now=Date.now();if(shell.last)shell.gaps=shell.gaps.concat([now-shell.last]);shell.last=now}}
 Timer {id:done;interval:300;onTriggered:{
  var g=shell.gaps.slice().sort(function(a,b){return a-b}),worst=g[g.length-1],median=g[Math.floor(g.length/2)],took=shell.end-shell.start
  var mono=shell.lum.every(function(v,i,a){return !i||v>=a[i-1]-1e-6}),stats=shell.theme.fade
  console.log("LIVE_STATS frames="+g.length+" median="+median+"ms worst="+worst+"ms duration="+took+"ms steps="+shell.lum.length+" lag="+(shell.applied?shell.start-shell.applied:0)+"ms ipc="+JSON.stringify(stats))
  if(took<300||took>800)shell.fail("fade duration "+took)
  else if(!mono)shell.fail("fade is monotonic")
  else if(g.length<12||worst>50)shell.fail("frame pacing frames="+g.length+" worst="+worst)
  else if(stats.source!==("'''+('omarchy-shell' if shell_mode else 'theme.name')+'''")||stats.frames<12||stats.worstMs>50)shell.fail("themeStats "+JSON.stringify(stats))
  else if(shell.applied&&shell.start-shell.applied>25)shell.fail("starts with the shell palette, lag "+(shell.start-shell.applied))
  else{console.log("LIVE_PASSED");Qt.quit()}
 }}
 Timer {interval:30000;running:true;onTriggered:shell.fail("timeout")}
}''')
  proc=subprocess.Popen(['qs','-p',str(host/'shell.qml')],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  out=[]
  try:
   for line in proc.stdout:
    out.append(line)
    if 'LIVE_READY' in line:time.sleep(.3);theme(state,'catppuccin-latte')
   proc.wait(timeout=40)
  finally:
   if proc.poll() is None:proc.kill()
  log=''.join(out)
  assert 'LIVE_PASSED' in log and not any(x in log for x in ['LIVE_FAILURE=','ReferenceError','TypeError','is not a type','Binding loop']),log
  print(('omarchy-shell host: ' if shell_mode else 'plain host: ')+next(l for l in out if 'LIVE_STATS' in l).split('LIVE_STATS ')[1].strip())
run(False);run(True)
print('PASS: omarchy-style Loader hosts, editor open, theme swap fades monotonically at steady frame pacing, in step with the shell palette')
