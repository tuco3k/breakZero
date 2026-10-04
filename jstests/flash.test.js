'use strict';
// The home feed must never paint an unapproved post, not even for one frame (owner, 2026-10-04).
// A "paint" here is every task boundary: the browser renders between tasks, after microtasks, so
// anything still visible when the next task starts could have been on screen. Visibility is real
// CSS (jsdom computes `display` from our stylesheets).
const test = require('node:test');
const assert = require('node:assert/strict');
const { bz, active, dom } = require('./helpers');

const IG = 'https://www.instagram.com';
const PEOPLE = {
  followers: ['alice', 'bob.b', 'carol', 'fan'],
  following: ['alice', 'bob.b', 'carol', 'brand', 'celeb']
};
const ALLOWED = new Set(['alice', 'bob.b', 'carol']);
const nextTask = () => new Promise((r) => setTimeout(r, 0));

function page(url = IG + '/?variant=following', fixture = 'ig-feed-friends.html') {
  const { window } = dom(fixture, url);
  window.webkit = { messageHandlers: { bz: { postMessage: () => {} } } };
  const ctl = bz.install(window, {
    active: active('instagram', {}, true, 'togglesDecide', PEOPLE),
    state: { grant: null },
    strings: { caughtUp: 'Listo', finding: 'Buscando', hide: 'Ocultar' },
    limits: { blocked: null }
  }, { replace: () => {}, assign: () => {}, setInterval: () => 0 });
  return { window, doc: window.document, ctl };
}

function visible(window, el) {
  for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
    if (window.getComputedStyle(e).display === 'none') return false;
  }
  return true;
}

/* Author = the first profile link, as the filter defines it; null for non-posts. */
function author(el) {
  for (const a of el.querySelectorAll('a[href]')) {
    const m = /^(?:https:\/\/www\.instagram\.com)?\/([A-Za-z0-9._]+)\/?$/.exec(a.getAttribute('href'));
    if (m && !['explore', 'p', 'reel', 'stories', 'direct'].includes(m[1])) return m[1].toLowerCase();
  }
  return null;
}

/* Every block holding a post permalink counts as a post, whatever its tag. */
function posts(doc) {
  const out = new Set();
  for (const a of doc.querySelectorAll('main a[href^="/p/"], main a[href^="/reel/"]')) {
    let el = a.parentElement;
    while (el.parentElement && el.parentElement.tagName !== 'MAIN' &&
           el.parentElement.querySelectorAll('a[href^="/p/"], a[href^="/reel/"]').length <= 1) el = el.parentElement;
    out.add(el);
  }
  return [...out];
}

/* A post is painted if any of its links (permalink, header) is visible. */
function painted(window, post) {
  return [...post.querySelectorAll('a[href]')].some((a) => visible(window, a));
}

function flashes(window) {
  return posts(window.document).filter((p) => painted(window, p) && !ALLOWED.has(author(p))).map(author);
}

let n = 0;
function postHTML(user, tag = 'article') {
  n++;
  return `<div class="row"><${tag} class="p"><header><a href="/${user}/">${user}</a></header>` +
    `<img alt=""><a href="/p/X${n}/">foto</a><a href="/someone_else/">le gusta</a></${tag}></div>`;
}

test('bursts of new posts: no unapproved post is ever painted', async () => {
  const { window, doc } = page();
  const list = doc.getElementById('list');
  const users = ['alice', 'brand', 'celeb', 'bob.b', 'shoe_co', 'carol', 'x1', 'x2', 'x3', 'alice'];
  let seen = 0;
  for (let burst = 0; burst < 8; burst++) {
    list.insertAdjacentHTML('beforeend', users.map((u, i) => postHTML(users[(i + burst) % users.length])).join(''));
    await nextTask();
    assert.deepEqual(flashes(window), [], `burst ${burst}`);
    seen++;
  }
  assert.equal(seen, 8);
});

test('approved posts are visible by the next paint (no waiting for a timer)', async () => {
  const { window, doc } = page();
  doc.getElementById('list').insertAdjacentHTML('beforeend', postHTML('carol'));
  await nextTask();
  const carol = posts(doc).find((p) => author(p) === 'carol');
  assert.ok(painted(window, carol));
});

test('a reused post node that now shows a stranger is hidden before the next paint', async () => {
  const { window, doc } = page();
  doc.getElementById('list').insertAdjacentHTML('beforeend', postHTML('alice'));
  await nextTask();
  const post = posts(doc).find((p) => author(p) === 'alice');
  assert.ok(painted(window, post));
  // React keeps the node and swaps its content for the next item.
  post.querySelector('header a').setAttribute('href', '/brand/');
  post.querySelector('header a').textContent = 'brand';
  await nextTask();
  assert.deepEqual(flashes(window), []);
  // …and content replaced wholesale inside the same node.
  const other = posts(doc).find((p) => author(p) === 'bob.b');
  other.innerHTML = '<header><a href="/celeb/">celeb</a></header><a href="/p/NEW1/">foto</a>';
  await nextTask();
  assert.deepEqual(flashes(window), []);
});

test('posts that are not <article> elements are screened too (structural fallback)', async () => {
  const { window, doc } = page();
  doc.getElementById('list').insertAdjacentHTML('beforeend',
    ['brand', 'alice', 'celeb', 'carol'].map((u) => postHTML(u, 'section')).join(''));
  await nextTask();
  assert.deepEqual(flashes(window), []);
  const shown = posts(doc).filter((p) => painted(window, p)).map(author);
  assert.ok(shown.includes('alice') && shown.includes('carol'), 'approved ones still show');
});

test('arriving on the feed from another page: posts drawn as the URL changes never flash', async () => {
  const { window, doc } = page(IG + '/direct/inbox/', 'ig-thread.html');
  doc.body.insertAdjacentHTML('beforeend', '<main><div id="list"></div></main>');
  window.history.pushState({}, '', '/?variant=following');
  doc.getElementById('list').insertAdjacentHTML('beforeend', ['brand', 'alice'].map((u) => postHTML(u)).join(''));
  await nextTask();
  assert.deepEqual(flashes(window), []);
});

test('stories tray: a non-mutual circle is never painted', async () => {
  const { window, doc } = page();
  doc.getElementById('tray').insertAdjacentHTML('beforeend', '<a id="t-x" href="/stories/x9/">x</a><a id="t-c" href="/stories/carol/">c</a>');
  await nextTask();
  assert.equal(visible(window, doc.getElementById('t-x')), false);
  assert.equal(visible(window, doc.getElementById('t-c')), true);
});

test('removing a shown post above the screen keeps the scroll position (manual anchoring)', () => {
  const { window, doc } = page();
  const c = bz.compile(active('instagram', {}, true, 'togglesDecide', PEOPLE));
  const alice = doc.getElementById('p-alice');
  const bob = doc.getElementById('p-bob');
  bz.screenRoots(c, doc, '/', window.location.href, [doc.documentElement], window);
  assert.equal(alice.getAttribute('data-bz-fr'), 'ok');
  // Layout stub: alice is above the screen (600px tall), bob is on screen at y=40 until alice goes.
  let aliceGone = false;
  alice.getBoundingClientRect = () => ({ top: -700, bottom: -100 });
  bob.getBoundingClientRect = () => (aliceGone ? { top: -560, bottom: -60 } : { top: 40, bottom: 540 });
  const scrolls = [];
  window.scrollBy = (x, y) => scrolls.push(y);
  // React reuses alice's node for a stranger.
  alice.querySelector('header a').setAttribute('href', '/brand/');
  const origSet = alice.setAttribute.bind(alice);
  alice.setAttribute = (k, v) => { origSet(k, v); if (k === 'data-bz-fr' && v === 'no') aliceGone = true; };
  bz.screenRoots(c, doc, '/', window.location.href, [alice], window);
  assert.equal(alice.getAttribute('data-bz-fr'), 'no');
  assert.deepEqual(scrolls, [-600], 'scrolled back by exactly the removed height');
});

test('"Finding posts from your people…" while many are hidden in a row, gone when one shows', async () => {
  const { window, doc, ctl } = page();
  const list = doc.getElementById('list');
  list.insertAdjacentHTML('beforeend', ['x1', 'x2', 'x3', 'x4', 'x5'].map((u) => postHTML(u)).join(''));
  await nextTask();
  ctl.tick();
  const finding = doc.querySelector('[data-bz="finding"]');
  assert.ok(finding, 'shown after 5+ hidden in a row');
  assert.equal(finding.textContent, 'Buscando');
  assert.equal(doc.querySelector('[data-bz="caughtup"]'), null);
  list.insertAdjacentHTML('beforeend', postHTML('carol'));
  await nextTask();
  ctl.tick();
  assert.equal(doc.querySelector('[data-bz="finding"]'), null, 'a post from your people arrived');
});

test('diagnostics: structure report and the painted-unapproved counter', async () => {
  const { window, doc } = page();
  doc.getElementById('list').insertAdjacentHTML('beforeend', postHTML('brand', 'section'));
  await nextTask();
  const r = window.__bzFeedReport();
  assert.equal(r.feed, true);
  assert.equal(r.mainArticle, 5);
  assert.equal(r.discovered, 1, 'the <section> post was found structurally');
  assert.ok(r.firstPostShape.includes('article'), r.firstPostShape);
  assert.equal(r.permalinksOutsidePosts, 0);
  assert.ok(!JSON.stringify(r).includes('alice'), 'no usernames in the report');
  const c = bz.compile(active('instagram', {}, true, 'togglesDecide', PEOPLE));
  assert.equal(bz.paintedUnapproved(c, doc, '/', window.location.href), 0);
});
