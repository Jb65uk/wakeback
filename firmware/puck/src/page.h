// The puck's own web page: served at http://192.168.4.1/ on its setup WiFi (and on the dock WiFi while it's joined).
// Plain HTML + JS, no libraries, so it loads on a phone with no internet. Polls /api/status once a second.
// Everyday things (battery, tracks, record, WiFi, level, mounting, firmware) are in the open; the sensor
// internals live under "Advanced" so a sailor who just wants it to work isn't faced with them.
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
details summary{cursor:pointer;color:var(--mute);font-size:15px;text-transform:uppercase;letter-spacing:.04em;margin-bottom:8px}
#toast{position:fixed;left:12px;right:12px;top:10px;background:#0b1220;border:1px solid #334155;color:var(--ink);padding:10px 14px;border-radius:10px;font-size:14px;display:none;z-index:9}
</style></head><body>
<div id="toast"></div>
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
<div style="margin-top:10px"><button id="recbtn" onclick="post('/api/rec',{op:recOn?'stop':'start'})">Start recording</button></div>
<div class="msg" id="mode"></div>
</div>

<div class="card"><h2>On the boat</h2>
<div class="grid">
<div><span>Mounted</span><b id="orient">–</b></div>
<div><span>Level</span><b id="lvl">–</b></div>
</div>
<p class="msg">With the boat sat level (on the trolley is fine) tap <b>Boat is level</b>. Which way up it's mounted is worked out by itself while the puck sits still, or tell it here.</p>
<button onclick="post('/api/cal/level')">Boat is level</button>
<button class="dim" onclick="post('/api/cal/orient',{o:1})">Mounted on deck</button>
<button class="dim" onclick="post('/api/cal/orient',{o:2})">Mounted under the thwart</button>
</div>

<div class="card"><h2>Settings</h2>
<label>Puck number (1–99)</label><input type="number" id="puck" min="1" max="99">
<label>Dock / phone hotspot WiFi name</label><input type="text" id="ssid" autocapitalize="none">
<label>WiFi password (leave blank to keep the current one)</label><input type="password" id="pass">
<label>Record on its own</label>
<select id="autorec"><option value="1">Yes: start when the boat moves off, stop after 10 minutes still</option><option value="0">No: only the button starts and stops it</option></select>
<label class="chk"><input type="checkbox" id="autooff"> Switch itself off after 30 minutes still, off the pad</label>
<div><button onclick="saveSettings()">Save</button></div>
</div>

<div class="card"><h2>Tracks on the puck</h2>
<div id="tracks" class="msg">–</div>
<p class="msg">They upload to the dock or your phone's WakeBack app by themselves and are deleted from the puck once the dock has them. Download here if you want one now. About 18 hours of sailing fits.</p>
</div>

<div class="card"><h2>Firmware</h2>
<p class="msg">Running <b id="fw2"></b>. Choose a <b>puck.bin</b> from the GitHub release, then Update. Takes about a minute; the puck restarts. If the new firmware doesn't run, it goes back to this one.</p>
<form id="upf" method="POST" action="/update" enctype="multipart/form-data" onsubmit="return startUpdate()">
<input type="file" name="firmware" id="fwfile" accept=".bin"><div><button type="submit">Update</button></div></form>
<div class="msg" id="umsg"></div>
</div>

<div class="card"><h2>Puck</h2>
<button class="dim" onclick="finish()">Done: leave setup mode</button>
<button class="dim" onclick="post('/api/reboot')">Restart</button>
<button class="bad" onclick="if(confirm('Sleep now? Press the button to wake it.'))post('/api/sleep')">Sleep</button>
<div class="msg" id="pmsg">Hold the button 2 s to sleep, keep holding to 6 s for setup mode. Tap to start or stop recording.</div>
</div>

<div class="card"><details><summary>Advanced</summary>
<div class="grid">
<div><span>GPS detail</span><b id="gpsd">–</b></div>
<div><span>Compass</span><b id="mag">–</b></div>
<div><span>Twist from bow</span><b id="twist">–</b></div>
<div><span>Level offsets</span><b id="zero">–</b></div>
</div>
<p class="msg">Twist is learnt by itself from the compass against the GPS course while you sail straight; type it in if you know it. Heel should read positive when the boat heels to starboard.</p>
<label>Twist (degrees clockwise the puck's arrow is from the bow)</label>
<div style="display:flex;gap:8px"><input type="number" id="twistin" step="1" min="-180" max="180"><button onclick="post('/api/cal/twist',{deg:v('twistin')})">Set</button></div>
<button class="dim" onclick="post('/api/cal/flip')">Heel sign is backwards</button>
<button class="dim" onclick="if(confirm('Forget level, twist and mounting?'))post('/api/cal/reset')">Reset calibration</button>
</details></div>

<script>
let recOn=false,editing=false,finished=false;
const $=id=>document.getElementById(id),v=id=>$(id).value;
const fields=['puck','ssid','pass','autorec','autooff','twistin'];
// while a field has focus the poll leaves the form alone; once focus has moved off the form it fills again
fields.forEach(id=>{$(id).addEventListener('focus',()=>editing=true);$(id).addEventListener('blur',()=>setTimeout(()=>{const a=document.activeElement;if(!a||!fields.includes(a.id))editing=false},200))});
function fmt(n,d){return (n==null||isNaN(n))?'–':Number(n).toFixed(d)}
let toastT=0;function say(t,bad){const e=$('toast');e.textContent=t;e.style.borderColor=bad?'#f87171':'#334155';e.style.display='block';clearTimeout(toastT);toastT=setTimeout(()=>e.style.display='none',4000)}
// one POST helper: the reply goes in a toast at the top, so it's seen whichever card the button was in
function post(url,data){const fd=new URLSearchParams(data||{});return fetch(url,{method:'POST',body:fd}).then(r=>{if(!r.ok)return r.text().then(t=>{throw new Error(t||('HTTP '+r.status))});return r.json()}).then(j=>{if(j.msg)say(j.msg);poll();return j}).catch(e=>{say(finished?'Setup finished — you can close this page.':'Lost the puck: '+e.message,!finished)})}
function saveSettings(){editing=false;post('/api/settings',{puck:v('puck'),ssid:v('ssid'),pass:v('pass'),autorec:v('autorec'),autooff:$('autooff').checked?1:0}).then(()=>{$('pass').value=''})}
function finish(){finished=true;post('/api/setup/done');$('pmsg').textContent='Setup finished — you can close this page.'}
function kb(k){return k<1024?k+' KB':fmt(k/1024,1)+' MB'}
function fill(s){
 $('pn').textContent='puck '+s.puck;$('fw').textContent='v'+s.fw;$('fw2').textContent='v'+s.fw;
 const g=s.gps,fx=['no fix','dead reckoning','2D fix','3D fix','3D fix','time only'][g.fix]||'?';
 $('sog').textContent=g.fix>=2?fmt(g.sog,1):'–';const useCog=g.fix>=2&&g.sog>1,ch=s.imu.heading;$('cog').textContent=useCog?String(Math.round(g.cog)).padStart(3,'0')+'°':(ch>=0?String(Math.round(ch)%360).padStart(3,'0')+'°':'–');$('hdglbl').textContent=useCog?'Course (GPS)':'Heading (compass)';
 $('gps').innerHTML=g.ok?(g.fix>=3?'<span class="ok">Ready</span>':'<span class="warn">Searching…</span>'+(g.sats?' ('+g.sats+' sats)':'')):'<span class="bad">not found</span>';
 $('gpsd').innerHTML=g.ok?(fx+', '+g.sats+' sats'+(g.fix>=2?', ±'+fmt(g.hacc,1)+' m, '+fmt(g.hz,0)+' Hz':'')):'not found';
 const b=s.batt;$('batt').innerHTML=(b.mv>2500?b.pct+'% ('+fmt(b.mv/1000,2)+' V)':'none')+(b.on_pad?' <span class="ok">'+(b.charging=='full'?'full':'charging')+'</span>':'');
 const i=s.imu;$('heel').textContent=i.ok?fmt(i.heel,1)+'°'+(i.heel>0.5?' stbd':i.heel<-0.5?' port':''):'no IMU';$('pitch').textContent=i.ok?fmt(i.pitch,1)+'°'+(i.pitch>0.5?' bow up':i.pitch<-0.5?' bow down':''):'';
 recOn=s.rec.on;$('rec').innerHTML=recOn?'<span class="ok">yes</span>, '+Math.floor(s.rec.secs/60)+' min, '+s.rec.lines+' pts':(s.autorec?'waiting for the boat to move':'off');
 $('recbtn').textContent=recOn?'Stop recording':'Start recording';
 const sto=s.store;$('store').innerHTML=(sto.full?'<span class="bad">FULL</span> ':'')+kb(sto.free_kb)+' free, '+sto.files+' track'+(sto.files==1?'':'s');
 if(!finished)$('mode').textContent=s.wifi.dock_refused?'Dock refused the key — set the puck up again from the app.':s.wifi.mode=='setup'?'Setup WiFi on: leaves setup mode after 10 minutes with nobody looking.':s.wifi.mode=='dock'?'On the dock WiFi '+s.wifi.ssid+' ('+s.wifi.ip+'), dock '+(s.wifi.dock_ok?'answering':'not found'):'';
 $('orient').textContent=i.orientation=='thwart'?'under the thwart':i.orientation=='deck'?'on deck':'not sure yet (keep it still)';
 $('lvl').textContent=i.ok?((Math.abs(i.heel)<1.5&&Math.abs(i.pitch)<1.5)?'reads level':'heel '+fmt(i.heel,1)+'°, pitch '+fmt(i.pitch,1)+'°'):'no IMU';
 $('twist').textContent=fmt(i.twist,0)+'°'+(i.twist_learned?' (learnt)':' (learning)');
 $('mag').innerHTML=['<span class="bad">uncalibrated</span>','<span class="warn">rough</span>','<span class="warn">fair</span>','<span class="ok">good</span>'][i.mag]||'–';
 $('zero').textContent='heel '+fmt(i.zero_heel,1)+'°, pitch '+fmt(i.zero_pitch,1)+'°'+(i.flip?', heel flipped':'');
 if(!editing){$('puck').value=s.puck;$('ssid').value=s.wifi.ssid||'';$('autorec').value=s.autorec?1:0;$('autooff').checked=!!s.autooff;$('twistin').value=Math.round(i.twist)}
 const t=s.tracks||[];$('tracks').innerHTML=t.length?t.map(x=>'<div class="row"><span>'+x.name+(x.open?' <span class="ok">(recording)</span>':'')+' <span style="color:#64748b">'+kb(x.kb)+'</span></span><span>'+(x.open?'':'<a href="/tracks/'+x.name+'" download>download</a> &nbsp; <a href="#" onclick="if(confirm(\'Delete '+x.name+' from the puck?\'))post(\'/api/tracks/delete\',{name:\''+x.name+'\'});return false">delete</a>')+'</span></div>').join(''):'none';
}
function poll(){fetch('/api/status').then(r=>{if(!r.ok)throw new Error('HTTP '+r.status);return r.json()}).then(fill).catch(()=>{$('mode').textContent=finished?'Setup finished — you can close this page.':'Lost the puck. Is it still in setup mode?'})}
function startUpdate(){const f=$('fwfile').files[0];if(!f){$('umsg').textContent='Choose a puck.bin first.';return false}
 $('umsg').textContent='Sending '+(f.size/1024|0)+' KB… don\'t close this page.';const fd=new FormData();fd.append('firmware',f);
 fetch('/update',{method:'POST',body:fd}).then(r=>r.text()).then(t=>{$('umsg').textContent=t+' Restarting…';setTimeout(()=>location.reload(),15000)}).catch(e=>{$('umsg').textContent='Update failed: '+e});return false}
poll();setInterval(poll,1000);
</script></body></html>)HTML";
