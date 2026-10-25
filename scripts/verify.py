#!/usr/bin/env python3
"""OmaShot verification runner: selects checks from the change set, builds current binaries, runs each check with a
timeout and its output in a log file, and reports PASS/FAIL/BLOCKED/SKIP. Exits 0 only if every selected check passed.

  scripts/verify.py                 checks for uncommitted changes (staged, unstaged, untracked) vs HEAD
  scripts/verify.py --base main     ... plus everything committed since main
  scripts/verify.py --full          every repository check (static, headless, render identity, live)
  scripts/verify.py --shell         add real omarchy-shell checks (installed plugin must match this tree)
  scripts/verify.py CHECK...        only the named checks or groups;  --list shows them
  --no-live  skip live Wayland checks (reported, never a full pass)   --keep  keep logs on success   --why  explain selection
  --serial   run one check at a time (default: offscreen checks in parallel with the serial live lane, timing gates last)
  --desktop  run live checks on your visible desktop (default: a hidden headless Hyprland, so you can keep working)
See .agents/skills/verify-project/SKILL.md."""
import concurrent.futures as cf,json,os,pathlib,re,shutil,signal,subprocess,sys,tempfile,threading,time
root=pathlib.Path(__file__).resolve().parents[1]
LIVE_TOOLS=['grim','wl-paste','wl-copy','qrencode','zbarimg','tesseract','hyprctl']
# id: (group, command, prerequisites, binaries, timeout s)
def py(name,*a):return ['python3',f'tests/{name}.py',*a]
CHECKS={
 'fmt':('static',['cargo','fmt','--check'],[],[],120),
 'clippy':('static',['cargo','clippy','--all-targets','--locked','--','-D','warnings'],[],[],600),
 'cargo-test':('static',['cargo','test','--locked'],['magick'],[],600),
 'py-compile':('static',['sh','-c','python3 -m py_compile scripts/*.py tests/*.py'],[],[],60),
 'manifest':('static',['sh','-c','jq -e \'.id == "omashot" and (.entryPoints.overlay | length > 0)\' plugin/manifest.json >/dev/null && c=$(cargo metadata --no-deps --format-version 1 | jq -r ".packages[0].version") && m=$(jq -r .version plugin/manifest.json) && echo "Cargo $c manifest $m" && test "$c" = "$m"'],['jq'],[],60),
 'qmldir':('static',['sh','-c','cd plugin && for f in *.qml; do case $f in ShellPalette.qml|shell.qml|WindowCapture.qml) continue;; esac; grep -q " $f$" qmldir || { echo "$f missing from plugin/qmldir"; exit 1; }; done; echo all listed'],[],[],10),
 'plugin-validate':('static',['omarchy','plugin','validate','./plugin'],['omarchy'],[],60),
 'install':('headless',['bash','tests/install.sh'],[],[],120),
 'render-regression':('headless',py('render-regression'),['magick'],['debug'],300),
 'render-golden':('headless',py('render-golden'),['magick'],['debug'],300),
 'history-service':('headless',py('history-service'),[],['debug'],120),
 'editor-events':('headless',py('editor-events-smoke'),['qs'],['debug'],180),
 'editor-objects':('headless',py('editor-objects-smoke'),['qs'],['debug'],180),
 'editor-narrow':('headless',py('editor-narrow-smoke'),['qs'],['debug'],120),
 'editor-background':('headless',py('editor-background-smoke'),['qs','magick'],['release'],180),
 'editor-live':('headless',py('editor-live-smoke'),['qs'],['debug'],180),
 'theme-smoke':('headless',py('theme-smoke'),['qs'],[],120),
 'render-identity':('identity',py('render-identity'),['magick','git'],['release'],900),
 'ui-smoke':('live',py('ui-smoke'),['wayland','qs','magick'],['debug'],300),
 'capture-selector':('live',py('capture-selector-smoke'),['wayland','qs','magick'],['release'],180),
 'capture-flow':('live',py('capture-flow-smoke'),['wayland','qs','magick'],['release'],300),
 'isolated-window':('live',py('isolated-window-smoke'),['wayland','qs','magick'],['debug'],120),
 'scroll':('live',py('scroll-smoke'),['wayland','qs','magick'],['release'],180),
 'theme-live':('live',py('theme-live-smoke'),['wayland','qs'],['debug'],180),
 'live-scene-fidelity':('live',py('live-scene-fidelity'),['wayland','qs','magick'],['debug'],300),
 'editor-latency':('live',py('editor-latency-live','--max-ms','50'),['wayland','qs'],['release'],600),
 'shell-current':('shell',None,['wayland','shell'],['release'],30),
 'shell-latency':('shell',py('editor-latency-live','--shell','--max-ms','50'),['wayland','shell','qs'],['release'],1500),
}
# Timing gates run alone after everything else; other live checks share the desktop (focus, clipboard), so one at a time.
TIMED={'theme-live','editor-latency','shell-latency'}
CARGO={'clippy','cargo-test'}  # share cargo's build lock; run in one lane
GROUPS={g:[c for c,v in CHECKS.items() if v[0]==g] for g in ['static','headless','identity','live','shell']}
FULL=GROUPS['static']+GROUPS['headless']+GROUPS['identity']+GROUPS['live']
EDITOR=['editor-events','editor-objects','editor-narrow','editor-background','editor-live','live-scene-fidelity','editor-latency','ui-smoke']
# First matching rule wins per path; static checks always run. Unknown paths select FULL.
RULES=[
 # The timing gates measure QML input/fade paths; backend changes reach them only through --full.
 (r'^(src/|Cargo\.(toml|lock)$|build\.rs$)',[c for c in FULL if c not in TIMED]),
 (r'^(scripts/verify\.py|\.agents/skills/verify-project/)',FULL),
 (r'^plugin/(Editor\.qml|LiveScene\.qml|AnnotationGeometry\.js|BackgroundPanel\.qml)$',EDITOR),
 (r'^plugin/CaptureSelector\.qml$',['capture-selector','capture-flow','ui-smoke']),
 (r'^plugin/ScrollCapture\.qml$',['scroll','capture-flow']),
 (r'^plugin/(Main|QuickAccess)\.qml$',['ui-smoke','capture-flow','capture-selector','editor-latency']),
 (r'^plugin/WindowCapture\.qml$',['isolated-window']),
 (r'^plugin/Retention\.qml$',['history-service','ui-smoke']),
 (r'^plugin/manifest\.json$',['install']),
 (r'^plugin/',GROUPS['headless']+GROUPS['live']),  # Theme, ShellPalette, Icon(Button), qmldir, shell.qml, assets, new files
 (r'^(scripts/(install\.sh|install-state\.py|uninstall\.sh|omashot-ui)|packaging/)',['install']),
 (r'^tests/vpointer\.py$',['editor-latency']),
 (r'^tests/render-golden\.json$',['render-golden']),
 (r'^tests/install\.sh$',['install']),
 (r'^tests/[^/]+\.py$',None),  # the matching test itself
 (r'^(scripts/(doctor\.sh|brand-assets\.py|screenshots\.sh)|docs/|\.github/|\.gitignore$|[^/]+\.md$|LICENSE$|\.agents/|\.claude/)',[]),
]
TEST_IDS={v[1][1]:k for k,v in CHECKS.items() if v[1] and v[1][0]=='python3'}
def git(*a):return subprocess.run(['git',*a],cwd=root,capture_output=True,text=True,check=True).stdout
def changed(base):
 files={l[3:].split(' -> ')[-1] for l in git('status','--porcelain=v1','-uall').splitlines() if l}
 if base:files|=set(git('diff','--name-only',f'{base}...HEAD').split())
 return sorted(files)
def select(files,why):
 picked=list(GROUPS['static'])
 for f in files:
  rule=next(((p,c) for p,c in RULES if re.search(p,f)),None)
  if rule and rule[1] is None:rule=(rule[0],[TEST_IDS[f]]) if f in TEST_IDS else None  # unregistered test: add it to CHECKS
  extra=FULL if rule is None else rule[1]
  if why:print(f'  {f}: '+('unknown or unregistered path, full' if rule is None else ', '.join(extra) or 'static only'))
  picked+=extra
 return [c for c in CHECKS if c in picked]
def missing(req,env=None):
 env=os.environ if env is None else env
 out=[]
 for r in req:
  if r=='wayland':
   if not (env.get('WAYLAND_DISPLAY') and env.get('HYPRLAND_INSTANCE_SIGNATURE')):out.append('a Hyprland Wayland session (WAYLAND_DISPLAY, HYPRLAND_INSTANCE_SIGNATURE)')
   out+=[t for t in LIVE_TOOLS if not shutil.which(t)]
  elif r=='shell':
   if 'omarchy/shell' not in subprocess.run(['qs','list','--all'],capture_output=True,text=True).stdout:out.append('a running omarchy-shell (qs list --all)')
  elif not shutil.which(r):out.append(r)
 return sorted(set(out))
def shell_instance():
 m=re.search(r'Instance (\S+):(?:(?!Instance ).)*?omarchy/shell(?:(?!Instance ).)*?Launch time: ([^(]+)',subprocess.run(['qs','list','--all'],capture_output=True,text=True).stdout,re.S)
 return (m.group(1),m.group(2).strip()) if m else None
def shell_current(log):
 """Installed plugin/binary must equal this tree, and the shell must have started after the install."""
 home=pathlib.Path.home();dest=home/'.config/omarchy/plugins/omashot';problems=[];newest=0
 if not dest.is_dir():problems.append(f'{dest} missing: install with scripts/install.sh (ask the user first)')
 else:
  # Same file set as scripts/install-state.py installs.
  for src in sorted((root/'plugin').rglob('*')):
   if not src.is_file() or src.name=='README.md' or src.name.startswith('brand-preview.'):continue
   f=dest/src.relative_to(root/'plugin')
   if not f.is_file():problems.append(f'plugin/{src.relative_to(root/"plugin")} not installed')
   else:
    newest=max(newest,f.stat().st_mtime)
    if f.read_bytes()!=src.read_bytes():problems.append(f'installed {f.relative_to(dest)} differs from plugin/')
 for exe,src in [(home/'.local/bin/omashot',root/'target/release/omashot'),(home/'.local/bin/omashot-ui',root/'scripts/omashot-ui')]:
  if not exe.exists() or exe.read_bytes()!=src.read_bytes():problems.append(f'{exe} differs from {src.relative_to(root)}')
 inst=shell_instance()
 if inst and newest:
  started=time.mktime(time.strptime(inst[1],'%Y-%m-%d %H:%M:%S'))
  if started<newest-1:problems.append(f'omarchy-shell {inst[0]} started {inst[1]}, before the plugin files changed: run `omarchy restart shell`')
 log.write_text('\n'.join(problems or [f'installed plugin and binaries match this tree; shell {inst}'])+'\n')
 return not problems
class Nested:
 """A private Hyprland nested in the user's session: its window goes to a hidden special workspace and its only output
 is headless (mirroring the focused monitor's mode and scale), so live checks never show windows, take focus, move the
 real pointer or touch the real clipboard."""
 def __init__(self,dir):self.dir=dir;self.proc=None;self.env=None
 def start(self):
  mon=next(m for m in json.loads(subprocess.check_output(['hyprctl','-j','monitors'],text=True)) if m['focused'])
  # Runtime-only rule in the outer compositor (gone on the next config reload); aquamarine is the nested window's class.
  subprocess.run(['hyprctl','eval','hl.window_rule({ match = { class = "^aquamarine$" }, workspace = "special:omashot-verify silent" })'],capture_output=True,timeout=5)
  conf=self.dir/'nested-hyprland.conf'
  conf.write_text(f"monitor = , {mon['width']}x{mon['height']}@{mon['refreshRate']:.2f}, 0x0, {mon['scale']}\n"
   'animations {\n enabled = false\n}\nmisc {\n disable_hyprland_logo = true\n disable_splash_rendering = true\n}\necosystem {\n no_update_news = true\n no_donation_nag = true\n}\n')
  before={i['instance'] for i in json.loads(subprocess.check_output(['hyprctl','-j','instances'],text=True))}
  self.proc=subprocess.Popen(['Hyprland','-c',str(conf)],stdin=subprocess.DEVNULL,stdout=(self.dir/'nested-hyprland.log').open('wb'),stderr=subprocess.STDOUT,start_new_session=True)
  for _ in range(100):
   inst=[i for i in json.loads(subprocess.check_output(['hyprctl','-j','instances'],text=True)) if i['instance'] not in before and i['pid']==self.proc.pid]
   if inst or self.proc.poll() is not None:break
   time.sleep(0.1)
  if not inst:raise RuntimeError(f'nested Hyprland did not start, see {self.dir}/nested-hyprland.log')
  self.env={**os.environ,'WAYLAND_DISPLAY':inst[0]['wl_socket'],'HYPRLAND_INSTANCE_SIGNATURE':inst[0]['instance']}
  ctl=lambda *a:subprocess.run(['hyprctl',*a],env=self.env,capture_output=True,text=True,timeout=5).stdout
  ctl('output','create','headless')
  for _ in range(50):
   mons=json.loads(ctl('-j','monitors') or '[]')
   if [m['name'] for m in mons]==['HEADLESS-1']:return
   if 'HEADLESS-1' in [m['name'] for m in mons]:ctl('keyword','monitor','WAYLAND-1,disable')
   time.sleep(0.2)
  raise RuntimeError(f'nested Hyprland outputs: {[m["name"] for m in mons]}')
 def stop(self):
  if self.proc:kill(self.proc)
class Clipboard:
 """ui-smoke/capture-flow overwrite the clipboard; save the first offered type and restore it afterwards."""
 def __init__(self,dir):self.file=dir/'clipboard.bin';self.type=None
 def save(self):
  types=subprocess.run(['wl-paste','--list-types'],capture_output=True,text=True,timeout=5).stdout.split()
  if types:
   self.type=types[0]
   with self.file.open('wb') as out:subprocess.run(['wl-paste','--type',self.type],stdout=out,timeout=10)
 def restore(self):
  if self.type:subprocess.Popen(['wl-copy','--type',self.type],stdin=self.file.open('rb'),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
  else:subprocess.run(['wl-copy','--clear'],timeout=5)
RUNNING=set();STOP=threading.Event()
def kill(p):
 try:os.killpg(p.pid,signal.SIGTERM);p.wait(5)
 except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
 except ProcessLookupError:pass
def run(cmd,log,timeout,env=None):
 # Output goes to a file, never a pipe: a wl-copy daemon spawned by a test would inherit the pipe and hang the run.
 with log.open('wb') as out:
  p=subprocess.Popen(cmd,cwd=root,env=env,stdin=subprocess.DEVNULL,stdout=out,stderr=subprocess.STDOUT,start_new_session=True);RUNNING.add(p)
  try:return p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:kill(p);return 'timeout'
  finally:RUNNING.discard(p)
def main(argv):
 flags={a for a in argv if a.startswith('--')};names=[a for a in argv if not a.startswith('-')]
 base=argv[argv.index('--base')+1] if '--base' in argv else None
 if base:names.remove(base)
 unknown=flags-{'--full','--shell','--no-live','--keep','--why','--list','--base','--help','--serial','--desktop'}
 if '--help' in flags or '-h' in argv or unknown:print(__doc__+(f'\nUnknown option(s): {", ".join(sorted(unknown))}' if unknown else ''));return 2 if unknown else 0
 if '--list' in flags:
  for g,ids in GROUPS.items():print(f'{g}: '+' '.join(ids))
  return 0
 if names:
  bad=[n for n in names if n not in CHECKS and n not in GROUPS]
  if bad:print('Unknown check(s): '+', '.join(bad)+' (see --list)');return 2
  selected=[c for c in CHECKS if c in names or CHECKS[c][0] in names];scope='named checks'
 elif '--full' in flags:selected=list(FULL);scope='full'
 else:
  files=changed(base)
  if not files:print('No changes vs HEAD'+(f' or {base}' if base else '')+'. Pass --base REF for committed work, --full, or check names.');return 2
  print(f'{len(files)} changed path(s)'+(':' if '--why' in flags else ''));selected=select(files,'--why' in flags);scope='changed'
 if '--shell' in flags:selected+=[c for c in GROUPS['shell'] if c not in selected]
 skipped=[c for c in selected if CHECKS[c][0]=='live'] if '--no-live' in flags else []
 logs=pathlib.Path(tempfile.mkdtemp(prefix=time.strftime('omashot-verify-%Y%m%d-%H%M%S-')));results=[]
 print(f'Selected ({scope}): '+' '.join(selected)+f'\nLogs: {logs}')
 builds=[b for b in ['debug','release'] if any(b in CHECKS[c][3] for c in selected if c not in skipped)]
 for b in builds:
  t=time.monotonic();code=run(['cargo','build','--locked']+(['--release'] if b=='release' else []),logs/f'build-{b}.log',900)
  results.append((f'build-{b}','PASS' if code==0 else 'FAIL',time.monotonic()-t,'' if code==0 else f'exit {code}'))
  print(f'{results[-1][1]:7} {results[-1][0]:20} {results[-1][2]:6.1f}s',flush=True)
 built=all(r[1]=='PASS' for r in results);clip=None;shell_before=shell_instance() if '--shell' in flags else None;lock=threading.Lock()
 def check(c):
  group,cmd,req,bins,timeout=CHECKS[c];log=logs/f'{c}.log';t=time.monotonic()
  if c in skipped:r=(c,'SKIP',0,'--no-live')
  elif STOP.is_set():r=(c,'SKIP',0,'interrupted')
  elif need:=missing(req,nested.env if nested and group=='live' else None):r=(c,'BLOCKED',0,'missing '+', '.join(need))
  elif bins and not built:r=(c,'BLOCKED',0,'build failed')
  else:
   code=(0 if shell_current(log) else 1) if cmd is None else run(cmd,log,timeout,nested.env if nested and group=='live' else None)
   tail=[l for l in log.read_text(errors='replace').splitlines() if l.strip()][-1:] if log.exists() else []
   r=(c,'PASS' if code==0 else 'FAIL',time.monotonic()-t,'' if code==0 else (f'{code}: ' if code=='timeout' else f'exit {code}: ')+(tail[0][:160] if tail else ''))
  with lock:results.append(r);print(f'{r[1]:7} {c:20} {r[2]:6.1f}s  {r[3]}',flush=True)
 def lane(ids):
  for c in ids:check(c)
 runnable=[c for c in selected if c not in skipped];nested=None
 if '--desktop' not in flags and any(CHECKS[c][0]=='live' for c in runnable) and not missing(['wayland']) and shutil.which('Hyprland'):
  nested=Nested(logs)
  try:nested.start();print('Live checks run in a hidden headless Hyprland (--desktop to use your screen)')
  except Exception as e:nested.stop();nested.env={};results.append(('nested-session','FAIL',0,str(e)));print(f'FAIL    nested-session        {e}')  # live checks then report BLOCKED, never fall back to the desktop
 # Shell checks still use the real desktop clipboard; the nested session has its own.
 if any(c in ('ui-smoke','capture-flow') for c in runnable) and nested is None and not missing(['wayland']):clip=Clipboard(logs);clip.save()
 live=[c for c in selected if CHECKS[c][0] in ('live','shell') and c not in TIMED];timed=[c for c in selected if c in TIMED]
 offscreen=[c for c in selected if c not in live and c not in timed]
 try:
  if '--serial' in flags:lane(selected)
  else:
   # Offscreen checks in a pool next to the serial live lane; timing gates afterwards, with the machine otherwise idle.
   lanes=[[c for c in offscreen if c in CARGO]]+[[c] for c in offscreen if c not in CARGO]+[live]
   with cf.ThreadPoolExecutor(5) as ex:
    futures=[ex.submit(lane,l) for l in sorted(lanes,key=lambda l:l!=live) if l]
    try:
     for f in futures:f.result()
    except KeyboardInterrupt:
     STOP.set();[kill(p) for p in list(RUNNING)];ex.shutdown(cancel_futures=True);raise
   lane(timed)
 except KeyboardInterrupt:STOP.set();[kill(p) for p in list(RUNNING)];results.append(('interrupted','FAIL',0,'SIGINT/SIGTERM'));print('Interrupted')
 finally:
  if clip:clip.restore()
  if nested:nested.stop()
 order={c:i for i,c in enumerate([r[0] for r in results if r[0].startswith('build-')]+selected)};results.sort(key=lambda r:order.get(r[0],len(order)))
 if shell_before and shell_instance()!=shell_before:
  results.append(('shell-stable','FAIL',0,f'omarchy-shell restarted during the run ({shell_before} -> {shell_instance()}); another session? rerun'));print(f'FAIL    shell-stable          {results[-1][3]}')
 counts={s:sum(r[1]==s for r in results) for s in ['PASS','FAIL','BLOCKED','SKIP']}
 ok=counts['PASS']==len(results)
 (logs/'summary.json').write_text(json.dumps({'scope':scope,'head':git('rev-parse','--short','HEAD').strip(),'results':[dict(zip(['check','status','seconds','detail'],r)) for r in results]},indent=1))
 print(f'\n{"PASS" if ok else "NOT PASSED"}: '+', '.join(f'{v} {k.lower()}' for k,v in counts.items() if v)+f' ({scope} scope)')
 if ok and scope!='full':print('This is a selected subset, not full verification.')
 if ok and '--keep' not in flags:shutil.rmtree(logs)
 else:print(f'Logs kept in {logs}')
 return 0 if ok else 1
def interrupt(*_):raise KeyboardInterrupt
if __name__=='__main__':
 signal.signal(signal.SIGTERM,interrupt);sys.stdout.reconfigure(line_buffering=True)
 sys.exit(main(sys.argv[1:]))
