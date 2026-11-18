#!/usr/bin/env python3
"""Bounded Meshy asset generation. Credentials stay in the user's config directory.

Run `start`, then `advance` as tasks complete. Reuses saved IDs; never silently
retries a potentially billed POST. Only downloads successful GLBs and previews.
"""
import argparse
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / 'tools/meshy_tasks.json'
OUT = ROOT / 'assets/meshy'
API = 'https://api.meshy.ai/openapi/v2/text-to-3d'
ASSETS = {
 'runner_helmet': {
  'prompt': 'Single futuristic racing helmet for a friendly arcade robot runner. Chunky rounded aerodynamic shell, large dark wraparound visor, inset cheek vents, layered ear discs, small rear fins. Clean appealing industrial toy design, bold readable silhouette, symmetrical, isolated helmet only, no head no neck no body no stand. White ceramic shell with graphite mechanical trim. Game ready hard surface asset.',
  'texture': 'Pearl white ceramic helmet shell, dark graphite side panels, glossy nearly black wraparound visor with a thin cyan light stripe, fine recessed seams, tiny metallic ear vents, clean premium arcade racing equipment, no writing no logos.',
  'polycount': 3500},
 'reactor_pylon': {
  'prompt': 'Single compact futuristic fusion reactor generator pylon for a stylish arcade arena. Vertical cylindrical industrial machine, broad octagonal armored base, stacked layered metal rings, exposed central energy cylinder surrounded by four curved protective ribs, heavy top cap, cooling vents and panel seams. Symmetric self contained machine, no cables outside silhouette, no ground plane, no scene. Graphite gunmetal and teal metal with cyan energy chamber. High quality stylized hard surface game prop.',
  'texture': 'Premium stylized science fiction reactor, dark graphite armored panels, brushed teal metal ribs, recessed cyan energy chamber, copper small mechanical trim, clean edge highlights and fine panel seams, no writing no logos.',
  'polycount': 6000}
}

def call(suffix='', data=None):
 key = Path.home().joinpath('.config/meshy/api_key').read_text().strip()
 req = urllib.request.Request(API+suffix, data=json.dumps(data).encode() if data else None,
  headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=90) as response: return json.load(response)

def save(state):
 STATE.write_text(json.dumps(state,indent=2)+'\n')

def main():
 args=argparse.ArgumentParser(); args.add_argument('action', choices=['start','advance']); action=args.parse_args().action
 state=json.loads(STATE.read_text()) if STATE.exists() else {}
 OUT.mkdir(parents=True,exist_ok=True)
 for name, spec in ASSETS.items():
  row=state.setdefault(name, {'prompt':spec['prompt'],'texture_prompt':spec['texture'],'target_polycount':spec['polycount']})
  if action=='start' and 'preview_id' not in row:
   row['preview_id']=call(data={'mode':'preview','model_type':'smart-topology','ai_model':'meshy-t2.5','target_polycount':spec['polycount'],'prompt':spec['prompt'],'target_formats':['glb']})['result']
   save(state); print(name,'preview created',row['preview_id'],flush=True)
  if action=='advance' and row.get('preview_id'):
   task_id=row.get('refine_id',row['preview_id']); task=call('/'+task_id)
   print(name,task['status'],task.get('progress'),flush=True)
   row['status']=task['status']
   if task['status']=='SUCCEEDED':
    if 'refine_id' not in row:
     # Keep the geometry preview for visual QA before texturing.
     if task.get('thumbnail_url'): urllib.request.urlretrieve(task['thumbnail_url'], OUT/(name+'_geometry.png'))
     row['refine_id']=call(data={'mode':'refine','preview_task_id':row['preview_id'],'ai_model':'meshy-7','enable_pbr':True,'texture_resolution':'2k','texture_prompt':spec['texture'],'target_formats':['glb']})['result']
     print(name,'refine created',row['refine_id'],flush=True)
    else:
     dest=OUT/(name+'.glb')
     if not dest.exists():
      urllib.request.urlretrieve(task['model_urls']['glb'],dest)
      if task.get('thumbnail_url'): urllib.request.urlretrieve(task['thumbnail_url'], OUT/(name+'_preview.png'))
     row['file']=str(dest.relative_to(ROOT)); row['bytes']=dest.stat().st_size
   elif task['status'] in ['FAILED','CANCELED']: print('Task failed:',task.get('task_error'))
   save(state)

if __name__=='__main__': main()
