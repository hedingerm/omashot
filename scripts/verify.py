#!/usr/bin/env python3
"""OmaShot verification runner: selects checks from the change set, builds current binaries, runs each check with a
timeout and its output in a log file, and reports PASS/FAIL/BLOCKED/SKIP. Exits 0 only if every selected check passed.

  scripts/verify.py                 checks for uncommitted changes (staged, unstaged, untracked) vs HEAD
  scripts/verify.py --base main     ... plus everything committed since main
  scripts/verify.py --full          every repository check (static, headless, render identity, live)
  scripts/verify.py --shell         add real omarchy-shell checks (installed plugin must match this tree)
  scripts/verify.py CHECK...        only the named checks or groups;  --list shows them
  --no-live  skip live Wayland checks (reported, never a full pass)   --keep  keep logs on success   --why  explain selection
See .agents/skills/verify-project/SKILL.md."""
import json,os,pathlib,re,shutil,signal,subprocess,sys,tempfile,time
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
GROUPS={g:[c for c,v in CHECKS.items() if v[0]==g] for g in ['static','headless','identity','live','shell']}
FULL=GROUPS['static']+GROUPS['headless']+GROUPS['identity']+GROUPS['live']
EDITOR=['editor-events','editor-objects','editor-narrow','editor-background','editor-live','live-scene-fidelity','editor-latency','ui-smoke']
# First matching rule wins per path; static checks always run. Unknown paths select FULL.
RULES=[
 (r'^(src/|Cargo\.(toml|lock)$|build\.rs$)',FULL),
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
def missing(req):
 out=[]
 for r in req:
  if r=='wayland':
   if not (os.environ.get('WAYLAND_DISPLAY') and os.environ.get('HYPRLAND_INSTANCE_SIGNATURE')):out.append('a Hyprland Wayland session (WAYLAND_DISPLAY, HYPRLAND_INSTANCE_SIGNATURE)')
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
def run(cmd,log,timeout):
 # Output goes to a file, never a pipe: a wl-copy daemon spawned by a test would inherit the pipe and hang the run.
 with log.open('wb') as out:
  p=subprocess.Popen(cmd,cwd=root,stdin=subprocess.DEVNULL,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  try:return p.wait(timeout=timeout)
  except BaseException as e:
   try:os.killpg(p.pid,signal.SIGTERM);p.wait(5)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   except ProcessLookupError:pass
   if isinstance(e,subprocess.TimeoutExpired):return 'timeout'
   raise
def main(argv):
 flags={a for a in argv if a.startswith('--')};names=[a for a in argv if not a.startswith('-')]
 base=argv[argv.index('--base')+1] if '--base' in argv else None
 if base:names.remove(base)
 unknown=flags-{'--full','--shell','--no-live','--keep','--why','--list','--base','--help'}
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
 built=all(r[1]=='PASS' for r in results);clip=None;shell_before=shell_instance() if '--shell' in flags else None
 try:
  for c in selected:
   group,cmd,req,bins,timeout=CHECKS[c];log=logs/f'{c}.log';t=time.monotonic()
   if c in skipped:results.append((c,'SKIP',0,'--no-live'))
   elif need:=missing(req):results.append((c,'BLOCKED',0,'missing '+', '.join(need)))
   elif bins and not built:results.append((c,'BLOCKED',0,'build failed'))
   else:
    if c in ('ui-smoke','capture-flow') and clip is None:clip=Clipboard(logs);clip.save()
    code=(0 if shell_current(log) else 1) if cmd is None else run(cmd,log,timeout)
    tail=[l for l in log.read_text(errors='replace').splitlines() if l.strip()][-1:] if log.exists() else []
    results.append((c,'PASS' if code==0 else 'FAIL',time.monotonic()-t,'' if code==0 else (f'{code}: ' if code=='timeout' else f'exit {code}: ')+(tail[0][:160] if tail else '')))
   print(f'{results[-1][1]:7} {c:20} {results[-1][2]:6.1f}s  {results[-1][3]}',flush=True)
 except KeyboardInterrupt:results.append(('interrupted','FAIL',0,'SIGINT/SIGTERM'));print('Interrupted')
 finally:
  if clip:clip.restore()
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
