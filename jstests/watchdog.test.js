'use strict';
// Watchdog (ARCHITECTURE.md §4b): the page as it *is* must be allowed, checked every second and
// on every navigation event, independent of the route guard.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { bz, active, dom, KIT } = require('./helpers');

const vectors = JSON.parse(fs.readFileSync(path.join(KIT, 'Tests', 'CoreTests', 'Fixtures', 'route-vectors.json'), 'utf8'));

// Shared vectors: every step the guard redirects must also be a watchdog violation if the page
// somehow got there anyway; every step the guard allows must pass the watchdog.
for (const seq of vectors.sequences) {
  test('watchdog vectors: ' + seq.name, () => {
    const c = bz.compile(active(seq.platform, seq.settings || {}, seq.signedIn !== false, seq.shortForm || 'togglesDecide'));
    let state = { grant: null };
    let current = null;
    seq.steps.forEach((step, i) => {
      if (step.fresh) { current = null; state = { grant: null }; }
      const before = { grant: state.grant };
      const d = bz.decideURL(c, step.url, current, state);
      const where = `${seq.name} step ${i}: ${step.url}`;
      if (d.type === 'allow') {
        assert.equal(bz.watchdogCheck(c, step.url, state, null), null, where + ' (allowed page must pass)');
        current = step.url;
      } else if (d.type === 'redirect') {
        const v = bz.watchdogCheck(c, step.url, before, null);
        assert.ok(v, where + ' (forbidden page must be a violation)');
        assert.equal(v.to, d.to, where);
        current = new URL(d.to, step.url).href;
      }
    });
  });
}

test('watchdogCheck has no side effects and honors a DM reel grant', () => {
  const c = bz.compile(active('instagram'));
  const state = { grant: { ruleID: 'ig.route.reelOnce', key: 'AAA', returnTo: '/direct/t/1/' } };
  assert.equal(bz.watchdogCheck(c, 'https://www.instagram.com/reel/AAA/', state, null), null);
  const v = bz.watchdogCheck(c, 'https://www.instagram.com/reel/BBB/', state, null);
  assert.deepEqual(v, { reason: 'bounced', detail: null, ruleID: 'ig.route.reelOnce', to: '/direct/t/1/' });
  assert.equal(state.grant.key, 'AAA', 'state untouched');
  assert.deepEqual(bz.watchdogCheck(c, 'https://www.instagram.com/someone/', state, { blocked: 'dailyLimit' }),
    { reason: 'limit', detail: 'dailyLimit', ruleID: null, to: '/direct/inbox/' });
});

function page(url, opts = {}) {
  const fixture = url.includes('youtube') ? 'yt-watch.html' : 'ig-home.html';
  const { window } = dom(fixture, url);
  const posts = [];
  const replaced = [];
  const intervals = [];
  window.webkit = { messageHandlers: { bz: { postMessage: (m) => posts.push(m) } } };
  const raw = { push: window.History.prototype.pushState };   // a router holding the original
  const platform = url.includes('youtube') ? 'youtube' : 'instagram';
  const ctl = bz.install(window, {
    active: active(platform, opts.settings || {}, true, opts.shortForm || 'togglesDecide'),
    state: { grant: null },
    limits: opts.limits || { blocked: null }
  }, { replace: (u) => replaced.push(u), setInterval: (fn, ms) => intervals.push({ fn, ms }) });
  return { window, posts, replaced, ctl, intervals, raw, platform };
}

test('runs every second', () => {
  const { intervals } = page('https://www.instagram.com/');
  assert.equal(intervals.length, 1);
  assert.equal(intervals[0].ms, 1000);
});

test('catches a navigation that bypassed the guard (unhooked router), on the next tick', () => {
  const { window, raw, replaced, intervals } = page('https://www.instagram.com/');
  raw.push.call(window.history, {}, '', '/reels/');           // guard never saw this
  assert.equal(window.location.pathname, '/reels/');
  intervals[0].fn();                                          // one second later
  assert.deepEqual(replaced, ['/direct/inbox/']);
});

test('hashchange and pageshow trigger an immediate check', () => {
  const { window, raw, replaced } = page('https://www.instagram.com/');
  raw.push.call(window.history, {}, '', '/explore/');
  window.dispatchEvent(new window.Event('hashchange'));
  assert.deepEqual(replaced, ['/direct/inbox/']);
});

test('budget runs out mid-reel: native pushes new rules, the page stops, pauses and leaves', () => {
  const { window, replaced, posts, ctl } = page('https://www.instagram.com/reel/XYZ/', { shortForm: 'budgetAllowed' });
  const video = window.document.createElement('video');
  window.document.body.appendChild(video);
  let paused = 0;
  video.pause = () => { paused += 1; };
  ctl.watchdog();
  assert.deepEqual(replaced, [], 'budget left: the reel is fine');
  window.__bzUpdate({ active: active('instagram', {}, true, 'forcedBlocked') });
  assert.deepEqual(replaced, ['/direct/inbox/']);
  assert.equal(paused, 1, 'media paused');
  const v = posts.find((p) => p.type === 'violation');
  assert.equal(v.reason, 'outOfScope');
  assert.equal(v.ruleID, 'ig.route.reelOnce');
});

test('Shorts budget out on YouTube: the Short is moved to the normal watch page', () => {
  const { window, replaced } = page('https://m.youtube.com/shorts/abc', { shortForm: 'budgetAllowed' });
  window.__bzUpdate({ active: active('youtube', {}, true, 'forcedBlocked') });
  assert.deepEqual(replaced, ['/watch?v=abc']);
});

test('daily limit / schedule: whole platform blocked → landing, then quiet while there', () => {
  const { window, replaced, posts, ctl } = page('https://www.instagram.com/someone/');
  window.__bzUpdate({ limits: { blocked: 'dailyLimit' } });
  assert.deepEqual(replaced, ['/direct/inbox/']);
  assert.equal(posts.filter((p) => p.type === 'violation').length, 1);
  assert.equal(posts.find((p) => p.type === 'violation').detail, 'dailyLimit');
  // Now on the landing page (simulate the navigation), the watchdog only keeps media paused.
  const { window: w2, posts: p2, ctl: c2, replaced: r2 } = page('https://www.instagram.com/direct/inbox/', { limits: { blocked: 'schedule' } });
  c2.watchdog();
  c2.watchdog();
  assert.deepEqual(r2, []);
  assert.equal(p2.filter((p) => p.type === 'violation').length, 0);
  assert.ok(ctl && w2);
});

test('one violation per bypass, with a toast message, then debounced for 2 s', () => {
  const { window, raw, replaced, posts, ctl } = page('https://www.instagram.com/');
  raw.push.call(window.history, {}, '', '/explore/');
  ctl.watchdog();
  ctl.watchdog();
  ctl.watchdog();
  assert.deepEqual(replaced, ['/direct/inbox/']);
  const v = posts.filter((p) => p.type === 'violation');
  assert.equal(v.length, 1);
  assert.equal(v[0].reason, 'blocked');
  assert.equal(v[0].ruleID, 'ig.route.explore');
});

test('a bypassed move from a DM thread to a reel is still granted (no false alarm)', () => {
  const { window, raw, replaced, ctl } = page('https://www.instagram.com/direct/t/5/');
  raw.push.call(window.history, {}, '', '/reel/SENT1/');
  ctl.watchdog();
  ctl.watchdog();
  assert.deepEqual(replaced, []);
  assert.equal(ctl.state.grant.key, 'SENT1');
});

test('a broken watchdog tick is reported, never thrown into the page', () => {
  const { window, raw, posts, ctl } = page('https://www.instagram.com/');
  raw.push.call(window.history, {}, '', '/explore/');
  window.document.querySelectorAll = () => { throw new Error('boom'); };
  assert.doesNotThrow(() => ctl.watchdog());
  assert.ok(posts.some((p) => p.type === 'filterError' && p.id === 'watchdog'));
});

// QUESTIONS #27 (owner, 2026-10-01): "no autoplay chains", not "no playback".
test('a video you open can play: nothing pauses it, wraps play(), or flags it', () => {
  const { window } = dom('yt-watch.html', 'https://m.youtube.com/watch?v=CHOSEN');
  const originalPlay = window.HTMLMediaElement.prototype.play;
  const posts = [];
  const replaced = [];
  window.webkit = { messageHandlers: { bz: { postMessage: (m) => posts.push(m) } } };
  const ctl = bz.install(window, { active: active('youtube'), state: { grant: null } },
    { replace: (u) => replaced.push(u), setInterval: () => 0 });
  assert.equal(window.HTMLMediaElement.prototype.play, originalPlay, 'play() is never wrapped');
  const video = window.document.getElementById('video');
  let paused = 0;
  video.pause = () => { paused += 1; };
  video.dispatchEvent(new window.Event('play'));
  video.dispatchEvent(new window.Event('playing'));
  for (let i = 0; i < 5; i++) ctl.watchdog();   // five seconds of playback
  assert.equal(paused, 0, 'never paused while it plays');
  assert.deepEqual(replaced, []);
  assert.equal(posts.filter((p) => p.type === 'violation').length, 0);
  assert.ok(posts.some((p) => p.type === 'media' && p.event === 'playing'));
});

test('finishing it never advances: an unhooked autoplay is caught by the watchdog', () => {
  const { window, raw, replaced, posts, ctl } = page('https://m.youtube.com/watch?v=CHOSEN');
  const video = window.document.getElementById('video');
  video.dispatchEvent(new window.Event('ended'));
  raw.push.call(window.history, {}, '', '/watch?v=NEXT');   // the site's autoplay, past our hooks
  ctl.watchdog();
  assert.deepEqual(replaced, ['/watch?v=CHOSEN'], 'back to the video you chose');
  const v = posts.find((p) => p.type === 'violation');
  assert.equal(v.reason, 'autoAdvance');
});

test('finishing it never advances: the hooked router is refused, but your own next pick works', () => {
  const { window, replaced } = page('https://m.youtube.com/watch?v=CHOSEN');
  const video = window.document.getElementById('video');
  video.dispatchEvent(new window.Event('ended'));
  window.history.pushState({}, '', '/watch?v=NEXT');
  assert.deepEqual(replaced, ['https://m.youtube.com/watch?v=CHOSEN']);
  assert.equal(window.location.search, '?v=CHOSEN', 'still on the finished video');
  window.document.body.dispatchEvent(new window.Event('pointerdown'));   // you tap another video
  window.history.pushState({}, '', '/watch?v=PICKED');
  assert.equal(window.location.search, '?v=PICKED');
});
