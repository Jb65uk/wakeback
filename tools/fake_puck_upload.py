#!/usr/bin/env python3
"""Pretend to be a puck landing on the dock: POST a log file to the server.

Usage: python tools/fake_puck_upload.py data/sessions/2026-09-22/puck1_174500.csv [--puck puck1] [--dock http://localhost:5000]
"""
import argparse, os, sys, urllib.request, uuid

ap = argparse.ArgumentParser()
ap.add_argument('file')
ap.add_argument('--puck', default='')
ap.add_argument('--dock', default='http://localhost:5000')
a = ap.parse_args()

boundary = uuid.uuid4().hex
name = os.path.basename(a.file)
with open(a.file, 'rb') as f: data = f.read()
body = b''
if a.puck:
    body += f'--{boundary}\r\nContent-Disposition: form-data; name="puck"\r\n\r\n{a.puck}\r\n'.encode()
body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
         f'Content-Type: application/octet-stream\r\n\r\n').encode() + data + f'\r\n--{boundary}--\r\n'.encode()
req = urllib.request.Request(a.dock + '/api/upload', data=body, method='POST',
                             headers={'Content-Type': f'multipart/form-data; boundary={boundary}'})
with urllib.request.urlopen(req) as r:
    print(r.status, r.read().decode())
