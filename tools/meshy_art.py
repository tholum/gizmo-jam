#!/usr/bin/env python3
"""Bounded Meshy task ledger for the art pass (sibling of meshy_assets.py).

Every task is created under a unique name and its ID is written to
tools/meshy_tasks.json before anything else happens. A name that already has a
record is never POSTed again: a failed or ambiguous POST is recorded as such and
must be reconciled by hand (`recent <endpoint>` lists what the account really
has). The API key is read from ~/.config/meshy/api_key at call time and is never
printed or stored.

  meshy_art.py balance
  meshy_art.py create <name> <endpoint> <payload.json> [--cost N]
  meshy_art.py status [<name> ...]
  meshy_art.py fetch <name> <dotted.result.key> <dest>
  meshy_art.py recent <endpoint>
  meshy_art.py library [search]
  meshy_art.py spent
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / 'tools/meshy_tasks.json'
BASE = 'https://api.meshy.ai'
SECTION = 'art_pass'
BUDGET = 1500
ENDPOINTS = {
    'text-to-3d': '/openapi/v2/text-to-3d',
    'image-to-3d': '/openapi/v1/image-to-3d',
    'text-to-image': '/openapi/v1/text-to-image',
    'image-to-image': '/openapi/v1/image-to-image',
    'rigging': '/openapi/v1/rigging',
    'animations': '/openapi/v1/animations',
    'text-to-motion': '/openapi/v1/text-to-motion',
    'retexture': '/openapi/v1/retexture',
    'remesh': '/openapi/v1/remesh',
}


def call(path, data=None, method=None):
    key = Path.home().joinpath('.config/meshy/api_key').read_text().strip()
    req = urllib.request.Request(
        BASE + path, data=json.dumps(data).encode() if data is not None else None, method=method,
        headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json',
                 'User-Agent': 'asset-pipeline/1.0'})
    with urllib.request.urlopen(req, timeout=120) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def load():
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    state.setdefault(SECTION, {'budget': BUDGET, 'tasks': {}})
    return state


def save(state):
    STATE.write_text(json.dumps(state, indent=2) + '\n')


def spent(state):
    total = 0
    for row in state[SECTION]['tasks'].values():
        # Until Meshy reports the real figure, count the estimate as spent.
        total += row.get('consumed_credits', row.get('estimated_credits', 0)) if row.get('status') not in ('FAILED', 'CANCELED', 'POST_REJECTED') else row.get('consumed_credits', 0)
    return total


def dig(obj, dotted):
    for part in dotted.split('.'):
        obj = obj[int(part)] if isinstance(obj, list) else obj[part]
    return obj


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action')
    parser.add_argument('args', nargs='*')
    parser.add_argument('--cost', type=int, default=0)
    opts = parser.parse_args()
    state = load()
    tasks = state[SECTION]['tasks']
    if opts.action == 'balance':
        print(call('/openapi/v1/balance'))
    elif opts.action == 'spent':
        for name, row in tasks.items():
            print(f"{name:34s} {row['endpoint']:14s} {row.get('status','?'):12s} {row.get('consumed_credits', '~' + str(row.get('estimated_credits', 0)))}")
        print('TOTAL', spent(state), 'of', BUDGET)
    elif opts.action == 'create':
        name, endpoint, payload_file = opts.args
        if name in tasks:
            sys.exit(f'{name} already has a record ({tasks[name].get("id")}); refusing to POST again')
        if spent(state) + opts.cost > BUDGET:
            sys.exit('budget exceeded; stop generating')
        payload = json.loads(Path(payload_file).read_text())
        # Substitute "@task:<name>" with a recorded task ID.
        for k, v in list(payload.items()):
            if isinstance(v, str) and v.startswith('@task:'):
                payload[k] = tasks[v[6:]]['id']
        row = {'endpoint': endpoint, 'payload': payload, 'estimated_credits': opts.cost,
               'created': time.strftime('%Y-%m-%dT%H:%M:%S'), 'id': None, 'status': 'POSTING'}
        tasks[name] = row
        save(state)
        try:
            row['id'] = call(ENDPOINTS[endpoint], payload)['result']
            row['status'] = 'PENDING'
        except urllib.error.HTTPError as error:
            # A 4xx is a definite rejection: nothing was billed.
            row['status'] = 'POST_REJECTED' if 400 <= error.code < 500 else 'POST_UNKNOWN'
            row['error'] = f'{error.code} {error.read().decode(errors="replace")[:400]}'
        except Exception as error:  # timeout etc: may have been billed
            row['status'] = 'POST_UNKNOWN'
            row['error'] = repr(error)[:400]
        save(state)
        print(name, row['status'], row.get('id'), row.get('error', ''))
    elif opts.action == 'status':
        for name in (opts.args or [n for n, r in tasks.items() if r.get('status') in ('PENDING', 'IN_PROGRESS')]):
            row = tasks[name]
            if not row.get('id'):
                print(name, row['status'])
                continue
            task = call(ENDPOINTS[row['endpoint']] + '/' + row['id'])
            row['status'] = task['status']
            if 'consumed_credits' in task and task['status'] in ('SUCCEEDED', 'FAILED', 'CANCELED'):
                row['consumed_credits'] = task['consumed_credits']
            if task.get('task_error') and task['task_error'].get('message'):
                row['error'] = task['task_error']['message']
            save(state)
            print(name, task['status'], task.get('progress'), 'credits', task.get('consumed_credits'), row.get('error', ''))
    elif opts.action == 'show':
        row = tasks[opts.args[0]]
        task = call(ENDPOINTS[row['endpoint']] + '/' + row['id'])
        def keys(o, prefix=''):
            if isinstance(o, dict):
                for k, v in o.items(): keys(v, prefix + k + '.')
            elif isinstance(o, list):
                for i, v in enumerate(o): keys(v, prefix + str(i) + '.')
            else:
                text = str(o)
                print(prefix[:-1], '=', ('<url>' if text.startswith('http') else text[:100]))
        keys(task)
    elif opts.action == 'fetch':
        name, dotted, dest = opts.args
        row = tasks[name]
        task = call(ENDPOINTS[row['endpoint']] + '/' + row['id'])
        url = dig(task, dotted)
        dest_path = Path(dest)
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        req = urllib.request.Request(url, headers={'User-Agent': 'asset-pipeline/1.0'})
        with urllib.request.urlopen(req, timeout=300) as response:
            dest_path.write_bytes(response.read())
        print(dest_path, dest_path.stat().st_size)
    elif opts.action == 'recent':
        for task in call(ENDPOINTS[opts.args[0]] + '?page_size=20&sort_by=-created_at'):
            print(task.get('id'), task.get('status'), task.get('created_at'), task.get('consumed_credits'), str(task.get('prompt', ''))[:60])
    elif opts.action == 'library':
        query = ('?search=' + opts.args[0]) if opts.args else ''
        for a in call('/openapi/v1/animations/library' + query):
            print(a['action_id'], a['name'], a['category'], a.get('sub_category'), a.get('preview_url', ''))
    else:
        sys.exit('unknown action')


if __name__ == '__main__':
    main()
