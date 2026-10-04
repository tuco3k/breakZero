'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { bz, active, dom } = require('./helpers');

const hidden = (doc, id) => doc.getElementById(id).closest('[data-bz-hidden]') !== null;
const noop = () => {};

test('IG home: heuristics hide reel links, reels/explore tabs and suggestions, keep friends', () => {
  const c = bz.compile(active('instagram'));
  const { window } = dom('ig-home.html', 'https://www.instagram.com/');
  const doc = window.document;
  bz.runHeuristics(c, doc, '/', window.location.href, noop);
  assert.ok(hidden(doc, 'reel-link'));
  assert.ok(hidden(doc, 'tab-reels'));
  assert.ok(!hidden(doc, 'tab-explore'), 'search is Normal by default: its entry (/explore/) stays (QUESTIONS #58)');
  assert.ok(hidden(doc, 'sugg-wrap'), 'suggested people hidden 3 levels up');
  assert.ok(!hidden(doc, 'post-friend'));
  assert.ok(!hidden(doc, 'tab-direct'));
  assert.ok(!hidden(doc, 'tab-home'));
  assert.ok(!doc.querySelector('main').hasAttribute('data-bz-hidden'), 'never hides <main>');
  assert.deepEqual(bz.runCanaries(c, doc, '/', window.location.href, noop), []);
});

test('IG home: CSS hides sponsored posts by structure, not text', () => {
  const c = bz.compile(active('instagram'));
  const css = bz.cssFor(c, '/');
  assert.match(css, /article:has\(a\[href\*="\/ads\/"\]\)\{display:none!important\}/);
  assert.doesNotMatch(css, /main article\{/, 'hide-feed is opt-in');
  const all = bz.cssFor(bz.compile(active('instagram', { toggles: { 'ig.hideFeed': true } })), '/');
  assert.match(all, /main article\{display:none!important\}/);
});

test('IG thread is an allow zone: nothing hidden, no CSS, no canaries', () => {
  const c = bz.compile(active('instagram'));
  const { window } = dom('ig-thread.html', 'https://www.instagram.com/direct/t/123/');
  const doc = window.document;
  assert.equal(bz.runHeuristics(c, doc, '/direct/t/123/', window.location.href, noop), 0);
  assert.equal(doc.querySelectorAll('[data-bz-hidden]').length, 0);
  assert.equal(bz.cssFor(c, '/direct/t/123/'), '');
  assert.deepEqual(bz.runCanaries(c, doc, '/direct/t/123/', window.location.href, noop), []);
});

test('IG profile: reels tab and reel cells hidden, posts kept', () => {
  const c = bz.compile(active('instagram'));
  const { window } = dom('ig-profile.html', 'https://www.instagram.com/someone/');
  const doc = window.document;
  bz.runHeuristics(c, doc, '/someone/', window.location.href, noop);
  assert.ok(hidden(doc, 'tab-preels'));
  assert.ok(hidden(doc, 'grid-reel'));
  assert.ok(!hidden(doc, 'grid-post'));
  assert.ok(!hidden(doc, 'tab-posts'));
});

test('IG canary fires and blurs when the hiding filter is off', () => {
  // Simulate a broken heuristic: canary still on (its toggle), heuristic stripped.
  const a = active('instagram');
  a.recipe.heuristics = [];
  a.recipe.hide = [];
  const c = bz.compile(a);
  const { window } = dom('ig-home.html', 'https://www.instagram.com/');
  const doc = window.document;
  const failed = bz.runCanaries(c, doc, '/', window.location.href, noop);
  assert.deepEqual(failed.sort(), ['ig.canary.reelLinksHome', 'ig.canary.reelsTab']);
  assert.equal(doc.getElementById('tab-reels').getAttribute('data-bz-blur'), 'ig.canary.reelsTab');
  assert.ok(!doc.getElementById('tab-direct').hasAttribute('data-bz-blur'));
});

test('YT subscriptions: shorts shelf (CSS) and rogue shorts link (heuristic) covered; canary clean', () => {
  const c = bz.compile(active('youtube'));
  const { window } = dom('yt-subscriptions.html', 'https://m.youtube.com/feed/subscriptions');
  const doc = window.document;
  const path = '/feed/subscriptions';
  const css = bz.cssFor(c, path);
  assert.match(css, /ytm-reel-shelf-renderer/);
  bz.runHeuristics(c, doc, path, window.location.href, noop);
  assert.ok(hidden(doc, 'rogue-short'));
  assert.ok(!hidden(doc, 'vid1'), 'the shelf link must not climb into ytm-browse');
  assert.ok(!doc.querySelector('ytm-browse').hasAttribute('data-bz-hidden'));
  assert.deepEqual(bz.runCanaries(c, doc, path, window.location.href, noop), []);
});

test('YT watch: related canary trips if related isn\'t hidden by CSS', () => {
  const ok = bz.compile(active('youtube'));
  const { window } = dom('yt-watch.html', 'https://m.youtube.com/watch?v=A');
  assert.deepEqual(bz.runCanaries(ok, window.document, '/watch', window.location.href, noop), []);

  const a = active('youtube');
  a.recipe.hide = a.recipe.hide.filter((h) => h.id !== 'yt.hide.relatedM');
  const broken = bz.compile(a);
  const w2 = dom('yt-watch.html', 'https://m.youtube.com/watch?v=A').window;
  assert.deepEqual(bz.runCanaries(broken, w2.document, '/watch', w2.location.href, noop), ['yt.canary.related']);
});

test('a throwing filter is isolated and reported; others still run', () => {
  const a = active('instagram');
  a.recipe.heuristics.unshift({ id: 'bad', toggle: 'x', type: 'selector', pattern: '<<<not a selector', hideAncestor: 0 });
  const c = bz.compile(a);
  const { window } = dom('ig-home.html', 'https://www.instagram.com/');
  const reports = [];
  bz.runHeuristics(c, window.document, '/', window.location.href, (m) => reports.push(m));
  assert.deepEqual(reports, [{ type: 'filterError', id: 'bad' }]);
  assert.ok(hidden(window.document, 'reel-link'), 'the good heuristics still ran');
});

function installed(fixture, url, settings, state, extra) {
  const { window } = dom(fixture, url);
  const posts = [];
  const replaced = [];
  const intervals = [];
  window.webkit = { messageHandlers: { bz: { postMessage: (m) => posts.push(m) } } };
  const platform = url.includes('youtube') ? 'youtube' : 'instagram';
  const ctl = bz.install(window, Object.assign({
    active: active(platform, settings || {}),
    state: state || { grant: null },
    strings: { needsUpdate: 'NEEDS-UPDATE', report: 'REPORT' }
  }, extra || {}), { replace: (u) => replaced.push(u), setInterval: (fn, ms) => intervals.push({ fn, ms }) });
  return { window, posts, replaced, ctl, intervals };
}

test('install: reel from DM plays once; pushState to the next reel bounces to the thread', () => {
  const { window, replaced, ctl } = installed('ig-thread.html', 'https://www.instagram.com/direct/t/123/');
  window.history.pushState({}, '', '/reel/SHARED1/');
  assert.equal(window.location.pathname, '/reel/SHARED1/');
  assert.equal(ctl.state.grant.key, 'SHARED1');
  window.history.pushState({}, '', '/reel/NEXT2/');
  assert.equal(window.location.pathname, '/reel/SHARED1/', 'the forbidden push did not happen');
  assert.deepEqual(replaced, ['/direct/t/123/']);
});

test('install: SPA push to /reels/ and /explore/tags/ redirects to landing, /explore/ to search; style injected', () => {
  const { window, replaced } = installed('ig-home.html', 'https://www.instagram.com/');
  assert.ok(window.document.querySelector('style[data-bz="style"]'));
  window.history.pushState({}, '', '/reels/');
  window.history.pushState({}, '', '/explore/tags/cats/');
  window.history.pushState({}, '', '/explore/');
  assert.deepEqual(replaced, ['/direct/inbox/', '/direct/inbox/', '/explore/search/']);
  window.history.pushState({}, '', '/friend/');
  assert.equal(window.location.pathname, '/friend/');
});

test('install: History.prototype is patched too (routers holding a reference)', () => {
  const { window, replaced } = installed('ig-home.html', 'https://www.instagram.com/');
  window.History.prototype.pushState.call(window.history, {}, '', '/reels/');
  assert.deepEqual(replaced, ['/direct/inbox/']);
});

test('install: YT pushState to /shorts/ID rewrites to watch page', () => {
  const { window, replaced } = installed('yt-subscriptions.html', 'https://m.youtube.com/feed/subscriptions');
  window.history.pushState({}, '', '/shorts/abc123');
  assert.deepEqual(replaced, ['/watch?v=abc123']);
});

test('install: autoplay chain refused after video ended', () => {
  const { window, replaced } = installed('yt-watch.html', 'https://m.youtube.com/watch?v=A');
  const v = window.document.getElementById('video');
  v.dispatchEvent(new window.Event('ended'));
  window.history.pushState({}, '', '/watch?v=NEXT');
  assert.deepEqual(replaced, ['https://m.youtube.com/watch?v=A']);
  // A user tap afterwards makes the next navigation a choice.
  window.document.body.dispatchEvent(new window.Event('pointerdown'));
  window.history.pushState({}, '', '/watch?v=CHOSEN');
  assert.equal(window.location.search, '?v=CHOSEN');
});

test('install: canary overlay shown via tick, report posts ids; none in allow zones', async () => {
  const a = { toggles: {} };
  const { window, posts, ctl } = installed('ig-home.html', 'https://www.instagram.com/', a);
  // Break the filters on the live page, then tick.
  ctl.compiled.heuristics.length = 0;
  ctl.compiled.hide.length = 0;
  ctl.tick();
  const overlay = window.document.querySelector('[data-bz="overlay"]');
  assert.ok(overlay, 'overlay shown');
  assert.match(overlay.textContent, /NEEDS-UPDATE/);
  overlay.querySelector('button').click();
  assert.ok(posts.some((p) => p.type === 'report' && p.ids.includes('ig.canary.reelsTab')));
  // Navigating into DMs clears marks and the overlay.
  window.history.pushState({}, '', '/direct/inbox/');
  assert.equal(window.document.querySelector('[data-bz="overlay"]'), null);
  assert.equal(window.document.querySelectorAll('[data-bz-hidden],[data-bz-blur]').length, 0);
});

test('safe ancestor: a too-large hideAncestor stops below structural containers', () => {
  const a = active('instagram');
  a.recipe.heuristics = [{ id: 'greedy', toggle: 'x', type: 'anchorHref', pattern: '^/reel/', hideAncestor: 8 }];
  const c = bz.compile(a);
  const { window } = dom('ig-home.html', 'https://www.instagram.com/');
  const doc = window.document;
  bz.runHeuristics(c, doc, '/', window.location.href, noop);
  assert.ok(hidden(doc, 'reel-link'));
  assert.ok(!hidden(doc, 'post-friend'));
  assert.ok(!doc.querySelector('main').hasAttribute('data-bz-hidden'));
});

test('media diagnostics: passive, no URLs, first playing/stalled per element, every error', () => {
  const { window, posts } = installed('yt-watch.html', 'https://m.youtube.com/watch?v=A');
  const v = window.document.getElementById('video');
  v.dispatchEvent(new window.Event('playing'));
  v.dispatchEvent(new window.Event('playing'));
  v.dispatchEvent(new window.Event('stalled'));
  v.dispatchEvent(new window.Event('stalled'));
  v.dispatchEvent(new window.Event('error'));
  v.dispatchEvent(new window.Event('error'));
  const media = posts.filter((p) => p.type === 'media');
  assert.deepEqual(media.map((m) => m.event), ['playing', 'stalled', 'error', 'error']);
  assert.ok(media.every((m) => m.source === 'none' && m.kind === 'video'));
  assert.ok(!JSON.stringify(media).includes('http'), 'no URLs in reports');
  assert.equal(v.paused, true, 'listeners never call play/pause');
});

test('mediaReport: blob vs url source, error code passthrough', () => {
  const el = { tagName: 'VIDEO', currentSrc: 'blob:https://m.youtube.com/abc', error: { code: 4 } };
  assert.deepEqual(bz.mediaReport('error', el), { type: 'media', event: 'error', kind: 'video', code: 4, source: 'blob' });
  assert.equal(bz.mediaReport('playing', { tagName: 'AUDIO', src: 'https://x/y.mp3', error: null }).source, 'url');
});

test('IG search Off: the search entry is hidden like before (QUESTIONS #58)', () => {
  const c = bz.compile(active('instagram', { searchMode: 'off' }));
  const { window } = dom('ig-home.html', 'https://www.instagram.com/');
  bz.runHeuristics(c, window.document, '/', window.location.href, noop);
  assert.ok(hidden(window.document, 'tab-explore'));
});
