// Checks the viewer's race suggestions against made-up fleets:  node tools/test_race_suggest.mjs
// Runs the real suggestRaces() cut straight out of viewer/index.html, so there is one copy of the rules.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import assert from 'node:assert/strict';

const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'viewer', 'index.html'), 'utf8');
const m = html.match(/\/\/ ---- race-suggest:begin[\s\S]*?\/\/ ---- race-suggest:end/);
assert.ok(m, 'race-suggest block not found in viewer/index.html');
const rad = d => d * Math.PI / 180;
function hav(la1, lo1, la2, lo2) {
  const dLa = rad(la2 - la1), dLo = rad(lo2 - lo1);
  const a = Math.sin(dLa / 2) ** 2 + Math.cos(rad(la1)) * Math.cos(rad(la2)) * Math.sin(dLo / 2) ** 2;
  return 12742000 * Math.asin(Math.sqrt(a));
}
const suggestRaces = new Function('hav', m[0] + '\nreturn suggestRaces;')(hav);

// ---- a small sailing simulator: metres on a flat lake, wind from the north (boats beat up +y)
const C = [53.6503, -3.0102], KN = 1.943844;
function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
/** plan: [{kind:'ashore'|'mill'|'race'|'sail', mins, to?:[x,y]}], hz = fixes per second */
function boat(seed, plan, { t0, kn = 4.5, hz = 1, from = [0, -300], startAt = 0 }) {
  const R = rng(seed), dt = 1 / hz, v = kn / KN;
  let x = from[0] + (R() - 0.5) * 30, y = from[1] + (R() - 0.5) * 30, hdg = R() * 360, T = startAt * 60;
  const t = [], lat = [], lon = [];
  const put = () => { t.push(t0 + T * 1000); lat.push(C[0] + (y + (R() - 0.5) * 2) / 111320); lon.push(C[1] + (x + (R() - 0.5) * 2) / (111320 * Math.cos(rad(C[0])))); };
  const go = (h, sp) => { x += Math.sin(rad(h)) * sp * dt; y += Math.cos(rad(h)) * sp * dt; T += dt; put(); };
  for (const leg of plan) {
    const until = T + leg.mins * 60;
    if (leg.kind === 'ashore') { while (T < until) go(0, 0.02); }
    else if (leg.kind === 'sail') {                       // straight to a point (out to the start, or home)
      while (T < until) { const dx = leg.to[0] - x, dy = leg.to[1] - y; if (Math.hypot(dx, dy) < 15) { go(R() * 360, 0.2); continue; } go(Math.atan2(dx, dy) * 180 / Math.PI, v * 0.9); }
    } else if (leg.kind === 'mill') {                     // before the start: reach back and forth near the line, luff, circle
      const home = leg.at || [0, 0]; let turn = T;
      while (T < until) {
        if (T >= turn) { hdg = (Math.hypot(x - home[0], y - home[1]) > 60 ? Math.atan2(home[0] - x, home[1] - y) * 180 / Math.PI : R() * 360) + (R() - 0.5) * 60; turn = T + 12 + R() * 22; }
        go(hdg, v * (0.25 + R() * 0.5));
      }
    } else {                                              // race: windward/leeward laps with tacks and gybes
      let up = true, side = seed % 2 ? 1 : -1, last = T; const top = 380 + (R() - 0.5) * 20;
      while (T < until) {
        if (up && y > top) { up = false; last = T; } else if (!up && y < 0) { up = true; last = T; }
        if (Math.abs(x) > 110 && Math.sign(x) === (up ? side : -side) && T - last > 15) { side = -side; last = T; }
        const slow = T - last < 6 ? 0.6 : 1;
        go(up ? side * 43 : 180 - side * 20, v * (up ? 0.82 : 0.95) * slow * (0.95 + R() * 0.1));
      }
    }
  }
  return { n: t.length, t, lat, lon, start: t[0], end: t[t.length - 1] };
}
const at = (t0, min) => t0 + min * 60000;
const near = (got, want, tolMin, what) => assert.ok(Math.abs(got - want) <= tolMin * 60000, `${what}: got ${new Date(got).toISOString()} wanted ${new Date(want).toISOString()} ±${tolMin} min`);

const t0 = Date.UTC(2026, 9, 3, 10, 0, 0);
// A club morning: out to the line, mill 8 min, race 40, mill 12, race 35, home.
const day = [
  { kind: 'sail', mins: 6, to: [0, 0] }, { kind: 'mill', mins: 8 }, { kind: 'race', mins: 40 },
  { kind: 'mill', mins: 12 }, { kind: 'race', mins: 35 }, { kind: 'mill', mins: 4 }, { kind: 'sail', mins: 5, to: [0, -300] }, { kind: 'ashore', mins: 4 },
];

// 1. a fleet of five: two races, found to the minute or so, and called likely
{
  const fleet = [1, 2, 3, 4, 5].map(s => boat(s, day, { t0, kn: 4 + s * 0.25, hz: s === 5 ? 10 : 1 }));
  const r = suggestRaces(fleet);
  const good = r.filter(x => x.conf !== 'low');
  assert.equal(good.length, 2, 'fleet: two likely races, got ' + JSON.stringify(r.map(x => [new Date(x.start).toISOString(), new Date(x.end).toISOString(), x.conf, x.why])));
  near(good[0].start, at(t0, 14), 2, 'race 1 start');
  near(good[0].end, at(t0, 54), 3, 'race 1 end');
  near(good[1].start, at(t0, 66), 2, 'race 2 start');
  assert.equal(good[0].conf, 'high');
  assert.equal(good[0].boats, 5);
  assert.ok(r.every(x => x.start % 60000 === 0 && x.end % 60000 === 0), 'whole minutes');
  // the sail out and the sail home are never called likely
  assert.ok(r.filter(x => x.conf === 'low').every(x => x.end <= at(t0, 14) || x.start >= at(t0, 100)), 'only the edges are maybes');
}

// 2. one track: still finds both, but only ever as a maybe
{
  const r = suggestRaces([boat(7, day, { t0 })]);
  const races = r.filter(x => x.end - x.start >= 20 * 60000);
  assert.equal(races.length, 2, 'single: two races, got ' + JSON.stringify(r.map(x => [new Date(x.start).toISOString(), new Date(x.end).toISOString(), x.conf])));
  assert.ok(r.every(x => x.conf === 'low'), 'single track is never better than a maybe');
  near(races[0].start, at(t0, 14), 3, 'single race 1 start');
}

// 3. two boats that set off together: medium
{
  const r = suggestRaces([boat(11, day, { t0 }), boat(12, day, { t0, kn: 5 })]).filter(x => x.conf !== 'low');
  assert.equal(r.length, 2);
  assert.ok(r.every(x => x.conf === 'medium'));
}

// 4. a cruise with no start (just sailing about, one long stretch) isn't called a likely race
{
  const cruise = [{ kind: 'sail', mins: 3, to: [0, 0] }, { kind: 'race', mins: 50 }, { kind: 'ashore', mins: 5 }];
  const r = suggestRaces([boat(21, cruise, { t0 }), boat(22, cruise, { t0, startAt: 9 })]);
  assert.ok(r.every(x => x.conf === 'low'), 'no shared start: maybes only, got ' + JSON.stringify(r.map(x => [x.conf, x.why])));
}

// 5. nothing sensible in, nothing out
assert.deepEqual(suggestRaces([]), []);
assert.deepEqual(suggestRaces([boat(31, [{ kind: 'ashore', mins: 30 }], { t0 })]), []);
assert.deepEqual(suggestRaces([boat(32, [{ kind: 'mill', mins: 3 }], { t0 })]), []);

console.log('race suggestions: all checks passed');
