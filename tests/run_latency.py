#!/usr/bin/env python3
"""Test actual ENet through a private UDP delay/loss proxy. No host-network changes."""
import heapq
import json
from pathlib import Path
import random
import select
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'test-output/iterations/4/latency'
OUT.mkdir(parents=True, exist_ok=True)
GODOT = ROOT / '.tools/Godot_v4.5.1-stable_linux.x86_64'
rng = random.Random(43117)
front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
back = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
front.bind(('127.0.0.1', 0)); back.bind(('127.0.0.1', 0))
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reserve:
    reserve.bind(('127.0.0.1', 0)); server_port = reserve.getsockname()[1]
front.setblocking(False); back.setblocking(False)
logs, processes = [], []
queue, client_address = [], None
stats = {'configured_rtt_ms':150, 'jitter_per_direction_ms':15, 'loss_probability':0.01,
         'forwarded':0, 'dropped':0, 'transport':'private UDP proxy; actual production ENet and Session RPCs'}
try:
    for role, port in [('host', server_port), ('client', front.getsockname()[1])]:
        log = (OUT / (role+'.log')).open('w+')
        logs.append(log)
        command = [str(GODOT),'--headless','--path',str(ROOT),'--script','res://tests/latency_peer.gd','--',f'--role={role}',f'--port={port}']
        processes.append(subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT))
    started = time.monotonic()
    sequence = 0
    while time.monotonic()-started < 40:
        if all(p.poll() is not None for p in processes): break
        readable,_,_ = select.select([front, back],[],[],0.003)
        for source in readable:
            try: packet, address = source.recvfrom(65536)
            except BlockingIOError: continue
            if source is front:
                client_address=address; target_socket=back; destination=('127.0.0.1',server_port)
            else:
                if client_address is None: continue
                target_socket=front; destination=client_address
            if rng.random() < 0.01:
                stats['dropped']+=1; continue
            sequence+=1
            due=time.monotonic()+0.075+rng.uniform(-0.015,0.015)
            heapq.heappush(queue,(due,sequence,target_socket,destination,packet))
        while queue and queue[0][0] <= time.monotonic():
            _,_,target_socket,destination,packet=heapq.heappop(queue)
            target_socket.sendto(packet,destination)
            stats['forwarded']+=1
    passed=True
    for role,process,log in zip(['host','client'],processes,logs):
        if process.poll() is None:
            process.kill(); process.wait(); passed=False
        log.flush(); log.seek(0); content=log.read()
        print(role+':\n'+content)
        if process.returncode or 'LATENCY_PASS' not in content or 'ERROR:' in content: passed=False
    stats['passed']=passed
    (OUT/'results.json').write_text(json.dumps(stats,indent=2)+'\n')
    print('LATENCY_PROXY_'+('PASS' if passed else 'FAIL'),json.dumps(stats))
    if not passed: raise SystemExit(1)
finally:
    for p in processes:
        if p.poll() is None: p.kill(); p.wait()
    for log in logs: log.close()
    front.close(); back.close()
