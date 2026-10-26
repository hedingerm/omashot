#!/usr/bin/env python3
"""Verify global shortcut management against an isolated hypr/bindings.lua and a fake hyprctl."""
import json, os, pathlib, re, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[1]; binary=root/'target/debug/omashot'
# The fake compositor knows two defaults and, on reload, evaluates the OmaShot block like Omarchy's
# hyprland.lua would: defaults first, then hl.unbind/o.bind lines from the file the block loads.
FAKE=r'''#!/usr/bin/env python3
import json, os, re, sys
state=os.environ['FAKE_HYPR']; cfg=os.environ['XDG_CONFIG_HOME']+'/hypr/bindings.lua'
defaults=[{'modmask':64,'key':'S','description':'Screenshot','dispatcher':'exec','arg':'omarchy-cmd-screenshot'},
          {'modmask':0,'key':'Print','description':'Screenshot','dispatcher':'exec','arg':'omarchy-cmd-screenshot'},
          {'modmask':64,'key':'Return','description':'Terminal','dispatcher':'exec','arg':'xdg-terminal-exec'}]
if sys.argv[1:]==['reload']:
    binds=list(defaults); norm=lambda k:k.replace(' ','').upper()
    for path in re.findall(r'pcall\(dofile, "([^"]+)"\)',open(cfg).read()):
        if not os.path.exists(path): continue
        for kind,args in re.findall(r'^(hl\.unbind|o\.bind)\((.*)\)$',open(path).read(),re.M):
            a=re.findall(r'"([^"]*)"',args); *mods,key=a[0].split(' + ')
            mask=sum({'SUPER':64,'CTRL':4,'ALT':8,'SHIFT':1}[m] for m in mods)
            binds=[b for b in binds if not (b['modmask']==mask and b['key'].upper()==key.upper())]
            if kind=='o.bind': binds.append({'modmask':mask,'key':key,'description':a[1],'dispatcher':'exec','arg':a[2]})
    json.dump(binds,open(state,'w')); open(state+'.log','a').write('reload\n')
elif sys.argv[1:]==['-j','binds']:
    print(open(state).read() if os.path.exists(state) else json.dumps(defaults))
elif sys.argv[1:]==['configerrors']: print('')
else: sys.exit(1)
'''
with tempfile.TemporaryDirectory(prefix='omashot-bindings-test-') as td:
    td=pathlib.Path(td); (td/'bin').mkdir(); fake=td/'bin/hyprctl'; fake.write_text(FAKE); fake.chmod(0o755)
    env=dict(os.environ,XDG_DATA_HOME=str(td/'data'),XDG_CONFIG_HOME=str(td/'config'),FAKE_HYPR=str(td/'binds.json'),PATH=f"{td/'bin'}:{os.environ['PATH']}")
    def command(*args,ok=True):
        p=subprocess.run([str(binary),*args],env=env,capture_output=True,text=True); v=json.loads(p.stdout)
        assert (p.returncode==0)==ok,(args,p.stdout,p.stderr); return v
    status=command('bindings'); assert not status['available'] and 'Lua config' in status['reason']
    assert command('bindings','set','{"region":"SUPER + S"}',ok=False)['error']
    hypr=td/'config/hypr'; hypr.mkdir(parents=True); user=hypr/'bindings.lua'
    original='-- my own binds\no.bind("SUPER + B", "Browser", "chromium")\n'; user.write_text(original)
    status=command('bindings'); assert status['available'] and not status['installed'] and status['hyprland']
    assert {'keys':'SUPER + S','description':'Screenshot','command':'exec omarchy-cmd-screenshot'} in status['taken']
    assert [a['id'] for a in status['actions']][:2]==['open','region']
    for bad in ['{"region":"SUPER + S\\")os.execute(\\"x"}','{"nope":"SUPER + S"}','{"region":"SUPER + S","window":"super+s"}','{"region":"HYPER + S"}','["SUPER + S"]']:
        assert command('bindings','set',bad,ok=False)['error'],bad
    assert not (td/'config/omashot/hyprland-bindings.lua').exists() and user.read_text()==original
    v=command('bindings','set','{"region":"super + shift + s","history":"SUPER + S","ocr":""}')
    assert v['bindings']=={'region':'SUPER + SHIFT + S','history':'SUPER + S'},v
    assert v['replaced']=={'history':'Screenshot'} and v['missing']==[] and v['reloaded'] and v['installed'],v
    text=user.read_text(); assert text.startswith(original) and text.count('-- BEGIN OMASHOT')==1,text
    lua=(td/'config/omashot/hyprland-bindings.lua').read_text()
    assert 'hl.unbind("SUPER + S")\no.bind("SUPER + S", "OmaShot history", "omashot-ui history")' in lua,lua
    assert not any(b['keys']=='SUPER + S' for b in command('bindings')['taken']),'Replaced default must be gone'
    # Saving again keeps one block and remembers what an already replaced chord replaced.
    v=command('bindings','set','{"history":"SUPER + S","qr":"Print"}')
    assert v['replaced']=={'history':'Screenshot','qr':'Screenshot'} and user.read_text().count('-- BEGIN OMASHOT')==1,v
    # Bindings Hyprland did not register are reported instead of claimed.
    fake.write_text(FAKE.replace("json.dump(binds","binds=defaults;json.dump(binds"))
    assert command('bindings','set','{"region":"SUPER + ALT + S"}')['missing']==['region']
    fake.write_text(FAKE)
    v=command('bindings','remove'); assert not v['installed'] and user.read_text()==original,user.read_text()
    assert not (td/'config/omashot/hyprland-bindings.lua').exists()
    command('bindings','set','{"region":"SUPER + ALT + S"}'); command('bindings','set','{}')
    assert user.read_text()==original and not (td/'config/omashot/hyprland-bindings.lua').exists()
    # Unrelated config is never touched and stdout stays a single JSON value.
    assert 'error' not in command('config')
print('PASS: shortcuts validated, generated, hooked once into hypr/bindings.lua, verified via hyprctl, removed cleanly')
