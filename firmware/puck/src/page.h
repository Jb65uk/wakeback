// The puck's own web page: served at http://192.168.4.1/ on its setup WiFi (and on the dock WiFi while it's joined).
// Plain HTML + JS, no libraries, so it loads on a phone with no internet. Polls /api/status once a second.
#pragma once
#include <pgmspace.h>

static const char PAGE_HTML[] PROGMEM = R"HTML(<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WakeBack puck</title>
<style>
:root{--bg:#0f172a;--card:#1e293b;--ink:#e2e8f0;--mute:#94a3b8;--acc:#38bdf8;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.4 system-ui,sans-serif;padding:12px 12px 40px}
h1{font-size:20px;margin:4px 0 12px}h1 small{color:var(--mute);font-weight:400;font-size:13px;margin-left:8px}
h2{font-size:15px;margin:0 0 8px;color:var(--mute);text-transform:uppercase;letter-spacing:.04em}
.card{background:var(--card);border-radius:12px;padding:14px;margin-bottom:12px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:8px 14px}.grid div span{display:block;color:var(--mute);font-size:12px}
.big{font-size:30px;font-weight:600;line-height:1.1}
label{display:block;margin:10px 0 4px;color:var(--mute);font-size:13px}
input[type=text],input[type=number],input[type=password],select{width:100%;padding:9px;border-radius:8px;border:1px solid #334155;background:#0b1220;color:var(--ink);font-size:16px}
button{background:var(--acc);color:#082f49;border:0;border-radius:8px;padding:10px 14px;font-size:15px;font-weight:600;margin:6px 6px 0 0;cursor:pointer}
button.dim{background:#334155;color:var(--ink)}button.bad{background:var(--bad);color:#450a0a}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}
.row{display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-bottom:1px solid #334155}.row:last-child{border:0}
.row a{color:var(--acc)}.msg{color:var(--mute);font-size:13px;margin-top:6px;min-height:18px}
.chk{display:flex;align-items:center;gap:8px;margin:10px 0 0;color:var(--ink);font-size:15px}
</style></head><body>
<h1>WakeBack <span id="pn">puck</span><small id="fw"></small></h1>

<div class="card"><h2>Now</h2>
<div class="grid">
<div><span>Speed</span><div class="big"><span id="sog">–</span><small style="font-size:14px"> kn</small></div></div>
<div><span id="hdglbl">Heading</span><div class="big" id="cog">–</div></div>
<div><span>GPS</span><b id="gps">–</b></div>
<div><span>Battery</span><b id="batt">–</b></div>
<div><span>Heel</span><b id="heel">–</b></div>
<div><span>Pitch</span><b id="pitch">–</b></div>
<div><span>Recording</span><b id="rec">–</b></div>
<div><span>Storage</span><b id="store">–</b></div>
</div>
<div style="margin-top:10px"><button id="recbtn" onclick="post('/api/rec',{op:recOn?'stop':'start'})">Start recording</button>
<button class="dim" onclick="post('/api/cal/level').then(()=>{$('mode').textContent='Calibrated: heel and pitch read 0 here.'})">Boat is level: calibrate</button></div>
<div class="msg" id="mode"></div>
</div>

<div class="card"><h2>Calibration</h2>
<div class="grid">
<div><span>Mounted</span><b id="orient">–</b></div>
<div><span>Twist from bow</span><b id="twist">–</b></div>
<div><span>Compass</span><b id="mag">–</b></div>
<div><span>Level offsets</span><b id="zero">–</b></div>
</div>
<p class="msg">1. Sit the boat level (on the trolley is fine) and tap <b>Level now</b>.<br>
2. Mounted <b>deck</b> or <b>under thwart</b> is worked out from gravity while the puck sits still.<br>
3. Twist is learnt by itself from the compass against the GPS course while you sail straight, or type it in.</p>
<button onclick="post('/api/cal/level')">Level now</button>
<button class="dim" onclick="post('/api/cal/flip')">Heel sign is backwards</button>
<button class="dim" onclick="post('/api/cal/flippitch')">Pitch sign is backwards</button>
<button class="dim" onclick="if(confirm('Forget level, twist and mounting?'))post('/api/cal/reset')">Reset</button>
<label>Twist (degrees clockwise the puck's arrow is from the bow)</label>
<div style="display:flex;gap:8px"><input type="number" id="twistin" step="1" min="-180" max="180"><button onclick="post('/api/cal/twist',{deg:v('twistin')})">Set</button></div>
<label class="chk"><input type="checkbox" id="autotwist" onchange="post('/api/settings',{autotwist:this.checked?1:0})"> Learn twist from the compass while sailing</label>
</div>

<div class="card"><h2>Settings</h2>
<label>Puck number (1–99)</label><input type="number" id="puck" min="1" max="99">
<label>Dock / phone hotspot WiFi name</label><input type="text" id="ssid" autocapitalize="none">
<label>WiFi password (leave blank to keep the current one)</label><input type="password" id="pass">
<label>Record on its own</label>
<select id="autorec"><option value="1">Yes: start when the boat moves off, stop after 10 minutes still</option><option value="0">No: only the button starts and stops it</option></select>
<label>Points a second while moving</label>
<select id="rate"><option value="10">10 (best, about 5 h of sailing fits)</option><option value="5">5 (about 9 h)</option><option value="2">2 (days)</option></select>
<label class="chk"><input type="checkbox" id="autooff"> Switch itself off after 30 minutes still, off the pad</label>
<div><button onclick="saveSettings()">Save</button></div>
<div class="msg" id="smsg"></div>
</div>

<div class="card"><h2>Tracks on the puck</h2>
<div id="tracks" class="msg">–</div>
<p class="msg">They upload to the dock or your phone's WakeBack app by themselves and are deleted from the puck once the dock has them. Download here if you want one now.</p>
</div>

<div class="card"><h2>Firmware</h2>
<p class="msg">Running <b id="fw2"></b>. Choose a <b>puck.bin</b> from the GitHub release, then Update. Takes about a minute; the puck restarts. If the new firmware doesn't run, it goes back to this one.</p>
<form id="upf" method="POST" action="/update" enctype="multipart/form-data" onsubmit="return startUpdate()">
<input type="file" name="firmware" id="fwfile" accept=".bin"><div><button type="submit">Update</button></div></form>
<div class="msg" id="umsg"></div>
</div>

<div class="card"><h2>Puck</h2>
<button class="dim" onclick="post('/api/setup/done')">Done: leave setup mode</button>
<button class="dim" onclick="post('/api/reboot')">Restart</button>
<button class="bad" onclick="if(confirm('Sleep now? Press the button to wake it.'))post('/api/sleep')">Sleep</button>
<div class="msg">Hold the button 2 s to sleep, keep holding to 6 s for setup mode. Tap to start or stop recording.</div>
</div>

<script>
let recOn=false,editing=false,st=null;
const $=id=>document.getElementById(id),v=id=>$(id).value;
['puck','ssid','pass','autorec','rate','autooff','twistin'].forEach(id=>{$(id).addEventListener('focus',()=>editing=true)});
function fmt(n,d){return (n==null||isNaN(n))?'–':Number(n).toFixed(d)}
function post(url,data){const fd=new URLSearchParams(data||{});return fetch(url,{method:'POST',body:fd}).then(r=>r.json()).then(j=>{if(j.msg)$('smsg').textContent=j.msg;poll();return j}).catch(e=>{$('smsg').textContent='Lost the puck: '+e})}
function saveSettings(){editing=false;post('/api/settings',{puck:v('puck'),ssid:v('ssid'),pass:v('pass'),autorec:v('autorec'),rate:v('rate'),autooff:$('autooff').checked?1:0}).then(()=>{$('pass').value=''})}
function fill(s){st=s;
 $('pn').textContent='puck '+s.puck;$('fw').textContent='v'+s.fw;$('fw2').textContent='v'+s.fw;
 const g=s.gps,fx=['no fix','dead reckoning','2D fix','3D fix','3D fix','time only'][g.fix]||'?';
 $('sog').textContent=g.fix>=2?fmt(g.sog,1):'–';const useCog=g.fix>=2&&g.sog>1,ch=s.imu.heading;$('cog').textContent=useCog?String(Math.round(g.cog)).padStart(3,'0')+'°':(ch>=0?String(Math.round(ch)%360).padStart(3,'0')+'°':'–');$('hdglbl').textContent=useCog?'Course (GPS)':'Heading (compass)';
 $('gps').innerHTML=g.ok?('<span class="'+(g.fix>=3?'ok':'warn')+'">'+fx+'</span>, '+g.sats+' sats'+(g.fix>=2?', ±'+fmt(g.hacc,1)+' m':'')):'<span class="bad">not found</span>';
 const b=s.batt;$('batt').innerHTML=(b.mv>2500?fmt(b.mv/1000,2)+' V '+b.pct+'%':'none')+(b.on_pad?' <span class="ok">'+(b.charging=='full'?'full':'charging')+'</span>':'');
 const i=s.imu;$('heel').textContent=i.ok?fmt(i.heel,1)+'°'+(i.heel>0.5?' stbd':i.heel<-0.5?' port':''):'no IMU';$('pitch').textContent=i.ok?fmt(i.pitch,1)+'°'+(i.pitch>0.5?' bow up':i.pitch<-0.5?' bow down':''):'';
 recOn=s.rec.on;$('rec').innerHTML=recOn?'<span class="ok">yes</span>, '+Math.floor(s.rec.secs/60)+' min, '+s.rec.lines+' pts':(s.autorec?'waiting for the boat to move':'off');
 $('recbtn').textContent=recOn?'Stop recording':'Start recording';
 const sto=s.store;$('store').innerHTML=(sto.full?'<span class="bad">FULL</span> ':'')+fmt(sto.free_kb/1024,1)+' MB free, '+sto.files+' track'+(sto.files==1?'':'s');
 $('mode').textContent=s.wifi.mode=='setup'?'Setup WiFi on: leaves setup mode after 10 minutes with nobody looking.':s.wifi.mode=='dock'?'On the dock WiFi '+s.wifi.ssid+' ('+s.wifi.ip+'), dock '+(s.wifi.dock_ok?'answering':'not found'):'';
 $('orient').textContent=i.orientation=='thwart'?'under the thwart':i.orientation=='deck'?'on deck':'not sure yet (keep it still)';
 $('twist').textContent=fmt(i.twist,0)+'°'+(s.autotwist?(i.twist_learned?' (learnt)':' (learning)'):'');
 $('mag').innerHTML=['<span class="bad">uncalibrated</span>','<span class="warn">rough</span>','<span class="warn">fair</span>','<span class="ok">good</span>'][i.mag]||'–';
 $('zero').textContent='heel '+fmt(i.zero_heel,1)+'°, pitch '+fmt(i.zero_pitch,1)+'°'+(i.flip?', heel flipped':'')+(i.flip_pitch?', pitch flipped':'');
 if(!editing){$('puck').value=s.puck;$('ssid').value=s.wifi.ssid||'';$('autorec').value=s.autorec?1:0;$('rate').value=s.rate;$('autooff').checked=!!s.autooff;$('twistin').value=Math.round(i.twist);$('autotwist').checked=!!s.autotwist}
 const t=s.tracks||[];$('tracks').innerHTML=t.length?t.map(x=>'<div class="row"><span>'+x.name+(x.open?' <span class="ok">(recording)</span>':'')+' <span style="color:#64748b">'+fmt(x.kb/1024,1)+' MB</span></span><span>'+(x.open?'':'<a href="/tracks/'+x.name+'" download>download</a> &nbsp; <a href="#" onclick="if(confirm(\'Delete '+x.name+' from the puck?\'))post(\'/api/tracks/delete\',{name:\''+x.name+'\'});return false">delete</a>')+'</span></div>').join(''):'none';
}
function poll(){fetch('/api/status').then(r=>r.json()).then(fill).catch(()=>{$('mode').textContent='Lost the puck. Is it still in setup mode?'})}
function startUpdate(){const f=$('fwfile').files[0];if(!f){$('umsg').textContent='Choose a puck.bin first.';return false}
 $('umsg').textContent='Sending '+(f.size/1024|0)+' KB… don\'t close this page.';const fd=new FormData();fd.append('firmware',f);
 fetch('/update',{method:'POST',body:fd}).then(r=>r.text()).then(t=>{$('umsg').textContent=t+' Restarting…';setTimeout(()=>location.reload(),15000)}).catch(e=>{$('umsg').textContent='Update failed: '+e});return false}
poll();setInterval(poll,1000);
</script></body></html>)HTML";
