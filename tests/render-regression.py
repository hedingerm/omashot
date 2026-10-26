#!/usr/bin/env python3
"""Pixel/export regressions for annotation rendering, crop alpha and export."""
import json,os,pathlib,subprocess,tempfile,hashlib
root=pathlib.Path(__file__).resolve().parents[1];binary=root/'target/debug/omashot'
with tempfile.TemporaryDirectory(prefix='omashot-render-test-') as directory:
 d=pathlib.Path(directory);env=dict(os.environ,XDG_DATA_HOME=str(d/'data'),XDG_CONFIG_HOME=str(d/'config'))
 def run(*args):return json.loads(subprocess.check_output([str(binary),*map(str,args)],env=env,text=True))
 def pixel(path,x,y):return subprocess.check_output(['magick',str(path),'-format',f'%[pixel:p{{{x},{y}}}]','info:'],text=True).strip()
 source=d/'source.png';subprocess.run(['magick','-size','100x100','xc:white',str(source)],check=True)
 assert run('project',source)['saved'] is False
 empty=run('render',source,'[]','-');assert run('project',empty['path'])['saved'] is True
 result=run('render',source,json.dumps([{'type':'arrow','x':10,'y':80,'cx':50,'cy':0,'x2':90,'y2':80,'color':'#ff0000','width':4}]),'-')
 assert pixel(result['path'],50,40) not in ['srgba(255,255,255,1)','srgb(255,255,255)']
 assert pixel(result['path'],50,80) in ['srgba(255,255,255,1)','srgb(255,255,255)']
 curved=run('project',result['path']);assert curved['operations'][0]['cx']==50
 filled=run('render',source,'[{"type":"filled","x":10,"y":10,"w":40,"h":40,"color":"#ff0000"}]','-')
 assert pixel(filled['path'],30,30) in ['srgba(255,0,0,1)','srgb(255,0,0)']
 crop=run('render',source,'[{"type":"crop","x":-20,"y":-20,"w":140,"h":140}]','-')
 assert crop['width']==140
 assert float(subprocess.check_output(['magick',crop['path'],'-format','%[fx:p{0,0}.a]','info:'],text=True))==0
 exported=d/'alpha.png';run('export',crop['path'],exported)
 assert pixel(exported,0,0)==pixel(crop['path'],0,0)
 assert float(subprocess.check_output(['magick',str(exported),'-format','%[fx:p{0,0}.a]','info:'],text=True))==0
 layer=d/'layer.png';subprocess.run(['magick','-size','30x30','xc:blue',str(layer)],check=True)
 composed=run('render',source,json.dumps([{'type':'image','path':str(layer),'x':0,'y':100,'w':30,'h':30}]),'-')
 assert composed['height']==130 and composed['contentRect']['sourceH']==130
 project=run('project',composed['path']);asset=pathlib.Path(project['operations'][0]['path']);assert asset!=layer and asset.exists()
 layer.unlink();rerender=run('render',project['source'],json.dumps(project['operations']),'-');assert rerender['height']==130
 run('delete',composed['path']);assert not asset.exists()
 hashes=set()
 for style in ['standard','rounded','monospaced','outlined','boxed','rounded_boxed','monospaced_boxed']:
  rendered=run('render',source,json.dumps([{'type':'text','x':8,'y':10,'w':70,'h':28,'text':'Style','size':18,'color':'#345ac8','style':style}]),'--preview')
  hashes.add(hashlib.sha256(pathlib.Path(rendered['path']).read_bytes()).digest())
 assert len(hashes)==7, 'Text presets must produce seven distinct real raster styles'
 spotlight=run('render',source,'[{"type":"spotlight","x":10,"y":10,"w":70,"h":70,"radius":12}]','--preview')
 assert pixel(spotlight['path'],10,10) not in ['srgba(255,255,255,1)','srgb(255,255,255)']
 assert pixel(spotlight['path'],40,40) in ['srgba(255,255,255,1)','srgb(255,255,255)']
 backgrounds=run('backgrounds');assert len(backgrounds)==20 and all(pathlib.Path(b['path']).exists() for b in backgrounds)
 for b in backgrounds:
  assert b['width']==96 and b['height']==96
  rendered=run('render',source,json.dumps([{'type':'background','gradient_version':2,'preset':b['index'],'padding':48,'auto_balance':False,'shadow':False}]),'--preview')
  assert rendered['contentRect']['sourceW']==100
print('PASS: curved arrow pixels, filled shape, transparent expanded crop/export, composed-image persistence,20 renderer thumbnails')
