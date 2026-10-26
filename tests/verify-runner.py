#!/usr/bin/env python3
"""Regression checks for runner scheduling and truthful skip results, without desktop access."""
import contextlib, importlib.util, io, json, pathlib, tempfile

root=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('verify',root/'scripts/verify.py')
verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)
verify.CHECKS={'offscreen':('headless',['true'],[],[],1),'capture-flow':('live',['false'],['wayland'],[],1)}
verify.GROUPS={'headless':['offscreen'],'live':['capture-flow'],'shell':[]}
verify.git=lambda *a:'test-head'
with tempfile.TemporaryDirectory(prefix='omashot-runner-test-') as td:
    original=verify.tempfile.mkdtemp
    verify.tempfile.mkdtemp=lambda **kw:original(dir=td,**kw)
    def run(*args):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code=verify.main(list(args))
        return code,out.getvalue()
    for serial in [[],['--serial']]:
        code,out=run('offscreen','--keep',*serial)
        assert code==0 and 'PASS' in out,out
        code,out=run('offscreen','capture-flow','--no-live','--keep',*serial)
        assert code==1 and 'SKIP' in out and 'NOT PASSED' in out,out
        log=pathlib.Path(out.split('Logs: ',1)[1].splitlines()[0])
        results=json.loads((log/'summary.json').read_text())['results']
        assert {r['check']:r['status'] for r in results}=={'offscreen':'PASS','capture-flow':'SKIP'},results
    code,out=run('capture-flow','--no-live')
    assert code==1 and 'SKIP' in out,out
    # Skips must not wait for a build event before the build workers have started.
    verify.CHECKS['offscreen']=('headless',['true'],[],['debug'],1)
    verify.CHECKS['capture-flow']=('live',['false'],['wayland'],['debug'],1)
    verify.run=lambda *a,**kw:0
    code,out=run('offscreen','capture-flow','--no-live','--keep')
    assert code==1 and 'SKIP' in out and 'build-debug' in out,out
    for args in [('offscreen','--jobs','0'),('offscreen','--sessions','-1'),('--jobs',),('--jobs','abc'),('--base',)]:
        code,out=run(*args)
        assert code==2 and 'Invalid option' in out,(args,code,out)
print('PASS: single-check scheduling, skipped live checks fail visibly, invalid options rejected')
