#!/usr/bin/env python3
"""Pretend to be a puck landing on the dock: POST a log file to the server.

Usage: python tools/fake_puck_upload.py data/sessions/2026-09-22_southport-sc/puck1_174500.csv [--puck puck1] [--dock http://localhost:5000] [--key <puck key>]

The other tools import upload() from here, so there is one copy of the multipart form.
"""
import argparse, json, os, urllib.request, uuid


def upload(path, dock='http://localhost:5000', puck='', key='', timeout=30):
    """POST one track file to /api/upload. puck is 'puck3' or just '3'; key is the X-Puck-Key the app issued
    (with accounts on, uploads need a key or a sign-in). Returns the server's JSON reply; raises on an HTTP error."""
    boundary = uuid.uuid4().hex
    name = os.path.basename(path)
    with open(path, 'rb') as f: data = f.read()
    body = b''
    if puck:
        if str(puck).isdigit(): puck = f'puck{puck}'
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="puck"\r\n\r\n{puck}\r\n'.encode()
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
             f'Content-Type: application/octet-stream\r\n\r\n').encode() + data + f'\r\n--{boundary}--\r\n'.encode()
    headers = {'Content-Type': f'multipart/form-data; boundary={boundary}'}
    if key: headers['X-Puck-Key'] = key
    req = urllib.request.Request(dock.rstrip('/') + '/api/upload', data=body, method='POST', headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('--puck', default='')
    ap.add_argument('--dock', default='http://localhost:5000')
    ap.add_argument('--key', default='', help='the puck key the app issued (needed when the server has accounts on)')
    a = ap.parse_args()
    try:
        print(upload(a.file, a.dock, a.puck, a.key))
    except urllib.error.HTTPError as e:
        raise SystemExit(f'{e.code}: {e.read().decode(errors="replace")}')
