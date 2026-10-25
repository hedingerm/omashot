#!/usr/bin/env python3
"""Verify retention at shell startup without opening history, with isolated storage."""
import json, os, pathlib, shutil, subprocess, tempfile, time
root=pathlib.Path(__file__).resolve().parents[1]; binary=root/'target/debug/omashot'
with tempfile.TemporaryDirectory(prefix='omashot-retention-test-') as td:
    td=pathlib.Path(td); plugin=td/'plugin'; shutil.copytree(root/'plugin',plugin)
    env=dict(os.environ,OMASHOT_BACKEND=str(binary),XDG_DATA_HOME=str(td/'data'),XDG_CONFIG_HOME=str(td/'config'))
    def command(*args): return json.loads(subprocess.check_output([str(binary),*map(str,args)],env=env,text=True))
    fixture=td/'fixture.png'; subprocess.run(['magick','-size','40x30','xc:#7f62dd',str(fixture)],check=True)
    old=pathlib.Path(command('import',fixture)['path'])
    edited=pathlib.Path(command('render',old,'[{"type":"redact","x":1,"y":1,"w":4,"h":4}]','-')['path'])
    project=command('project',edited); original=pathlib.Path(project['source'])
    fresh=pathlib.Path(command('import',fixture)['path'])
    wallpaper=pathlib.Path(command('wallpaper','import',fixture)['path'])
    exported=td/'exported.png'; command('export',old,exported)
    command('config',json.dumps({'retention_days':1}))
    for p in (old,edited,original,exported,wallpaper): os.utime(p,(time.time()-2*86400,time.time()-2*86400))
    with (td/'shell.log').open('w') as log:
        shell=subprocess.Popen(['qs','-p',str(plugin)],env=env,stdout=log,stderr=log)
        try:
            deadline=time.monotonic()+10
            while old.exists() or edited.exists():
                assert shell.poll() is None,(td/'shell.log').read_text()
                if time.monotonic()>deadline: raise AssertionError('Startup service did not expire old history')
                time.sleep(.1)
            assert not original.exists() and not edited.with_suffix('.project.json').exists()
            assert fresh.exists() and exported.exists() and wallpaper.exists()
            command('config',json.dumps({'retention_days':0}))
            os.utime(fresh,(time.time()-100*86400,time.time()-100*86400))
            command('cleanup'); assert fresh.exists()
        finally:
            shell.terminate()
            try: shell.wait(timeout=5)
            except subprocess.TimeoutExpired: shell.kill(); shell.wait()
    logtext=(td/'shell.log').read_text(); assert 'ERROR' not in logtext,logtext
    earlier=pathlib.Path(command('import',fixture)['path'])
    later=pathlib.Path(command('render',earlier,'[]','-')['path'])
    second=int(time.time())-100
    os.utime(earlier,ns=(second*1_000_000_000+100,second*1_000_000_000+100))
    os.utime(later,ns=(second*1_000_000_000+900_000_000,second*1_000_000_000+900_000_000))
    history=command('history'); assert history[0]['path']==str(later),'History must order edits correctly within the same second'
print('PASS: startup retention expires captures/projects, preserves fresh captures/wallpapers/exports; 0 keeps everything')
