'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { bz, active, KIT } = require('./helpers');

const vectors = JSON.parse(fs.readFileSync(path.join(KIT, 'Tests', 'CoreTests', 'Fixtures', 'route-vectors.json'), 'utf8'));

// The same table drives RuleEngineTests.testSharedRouteVectors in Swift.
for (const seq of vectors.sequences) {
  test('route vectors: ' + seq.name, () => {
    const c = bz.compile(active(seq.platform, seq.settings || {}, seq.signedIn !== false, seq.shortForm || 'togglesDecide'));
    let state = { grant: null };
    let current = null;
    seq.steps.forEach((step, i) => {
      if (step.fresh) { current = null; state = { grant: null }; }
      const d = bz.decideURL(c, step.url, current, state);
      let got;
      if (d.type === 'allow') { got = 'allow'; current = step.url; }
      else if (d.type === 'redirect') { got = 'redirect:' + d.to; current = new URL(d.to, step.url).href; }
      else got = 'external';
      assert.equal(got, step.expect, `${seq.name} step ${i}: ${step.url}`);
    });
  });
}

test('capture encoding matches Swift', () => {
  assert.equal(bz.encodeComponent('abc-_.~@'), 'abc-_.~@');
  assert.equal(bz.encodeComponent('a&b=c'), 'a%26b%3Dc');
  assert.equal(bz.encodeComponent("it's(*)!"), 'it%27s%28%2A%29%21');
});

test('script loads with no browser globals at top level', () => {
  const vm = require('node:vm');
  const src = fs.readFileSync(require('./helpers').SCRIPT, 'utf8');
  const sandbox = { module: { exports: {} } };
  vm.runInNewContext(src, sandbox);
  assert.equal(typeof sandbox.module.exports.decide, 'function');
});

test('autoAdvance refused only right after media ended without a gesture', () => {
  const c = bz.compile(active('youtube'));
  const from = new URL('https://m.youtube.com/watch?v=A');
  const to = new URL('https://m.youtube.com/watch?v=B');
  const t = 1_000_000;
  assert.equal(bz.isAutoAdvance(c, from, to, { lastEndedAt: t, lastGestureAt: t - 5000, now: t + 3000 }), true);
  assert.equal(bz.isAutoAdvance(c, from, to, { lastEndedAt: t, lastGestureAt: t + 1000, now: t + 3000 }), false, 'user tapped');
  assert.equal(bz.isAutoAdvance(c, from, to, { lastEndedAt: 0, lastGestureAt: 0, now: t }), false, 'nothing ended');
  assert.equal(bz.isAutoAdvance(c, from, to, { lastEndedAt: t, lastGestureAt: 0, now: t + 60000 }), false, 'long after');
  const pl = new URL('https://m.youtube.com/watch?v=A&list=PL1');
  assert.equal(bz.isAutoAdvance(c, pl, to, { lastEndedAt: t, lastGestureAt: 0, now: t + 1000 }), false, 'playlist exempt');
  const same = new URL('https://m.youtube.com/watch?v=A&t=10');
  assert.equal(bz.isAutoAdvance(c, from, same, { lastEndedAt: t, lastGestureAt: 0, now: t + 1000 }), false, 'same video');
  const off = bz.compile(active('youtube', { toggles: { 'yt.autoplayOff': false } }));
  assert.equal(bz.isAutoAdvance(off, from, to, { lastEndedAt: t, lastGestureAt: 0, now: t + 1000 }), false);
});
