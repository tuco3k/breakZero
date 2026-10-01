'use strict';
// Old Instagram (ARCHITECTURE.md §4c): friends-only feed, stories tray, viewer skip, caught up,
// forced Following feed, setup scan, canaries. Usernames come from hrefs only, never text.
const test = require('node:test');
const assert = require('node:assert/strict');
const { bz, active, dom, recipe, storyGateRule } = require('./helpers');

const FRIENDS = { friends: ['alice', 'bob.b'] };
const IG = 'https://www.instagram.com';
const noop = () => {};
const ok = (doc, id) => doc.getElementById(id).getAttribute('data-bz-fr') === 'ok';

function compiled(settings = FRIENDS) {
  return bz.compile(active('instagram', settings));
}

function feedState() {
  return { postCount: -1, lastNewPostAt: 0, trayOrder: [], card: null, cardHref: null, caughtUpText: 'Listo' };
}

/* A live page with the script installed; navigation is recorded instead of performed. */
function page(fixture, url, opts = {}) {
  const { window } = dom(fixture, url);
  const posts = [];
  const nav = [];
  window.webkit = { messageHandlers: { bz: { postMessage: (m) => posts.push(m) } } };
  let now = opts.now || 1_000_000;
  const ctl = bz.install(window, {
    active: active('instagram', opts.settings || FRIENDS),
    state: { grant: null },
    strings: { needsUpdate: 'x', report: 'y', caughtUp: 'Listo' },
    limits: { blocked: null },
    scan: !!opts.scan
  }, {
    replace: (u) => nav.push(['replace', u]),
    assign: (u) => nav.push(['assign', u]),
    setInterval: () => 0,
    now: () => now
  });
  return { window, doc: window.document, posts, nav, ctl, advance: (ms) => { now += ms; } };
}

test('Swift and JS build the same story gate', () => {
  const r = recipe('instagram');
  const rule = storyGateRule(['bob.b', 'alice'], r.friendsFilter, true);
  // Same literal as FriendsTests.testGatePatternMatchesTheJavaScriptMirror.
  assert.equal(rule.pattern, '^/stories/(?!(?:alice|bob\\.b|highlights)(?:/|$))[^/]+(?:/|$)');
  assert.equal(rule.to, '/?variant=following');
});

test('off without a Friends list: no friends CSS, no gate; the setup scan is still available', () => {
  const c = bz.compile(active('instagram'));
  assert.equal(c.friends, null);
  assert.doesNotMatch(bz.cssFor(c, '/'), /data-bz-fr/);
  assert.ok(!c.routes.some((r) => r.rule.id === bz.GATE_ID));
  assert.ok(c.scan, 'scan works before the first friend exists');
});

test('feed CSS: default deny for posts and tray items, only on the feed', () => {
  const c = compiled();
  const css = bz.cssFor(c, '/');
  assert.match(css, /:is\(main article\):not\(\[data-bz-fr="ok"\]\)\{display:none!important\}/);
  assert.match(css, /:is\(a\[href\^="\/stories\/"\]\):not\(\[data-bz-fr="ok"\]\)\{display:none!important\}/);
  assert.match(css, /\[data-bz="caughtup"\]~\*\{display:none!important\}/);
  assert.doesNotMatch(bz.cssFor(c, '/stranger/'), /data-bz-fr/, 'profiles you open are untouched');
  assert.doesNotMatch(bz.cssFor(c, '/p/ABC/'), /data-bz-fr/, 'a post you open is untouched');
  assert.equal(bz.cssFor(c, '/direct/t/1/'), '', 'DMs are an allow zone');
  assert.match(bz.cssFor(c, '/stories/alice/1/'), /html:not\(\[data-bz-story-ok\]\) body\{visibility:hidden!important\}/);
});

test('feed: only friends\' posts are marked; author is the first profile href, not text', () => {
  const c = compiled();
  const { window } = dom('ig-feed-friends.html', IG + '/?variant=following');
  const doc = window.document;
  const r = bz.runFriendsFeed(c, doc, '/', window.location.href, feedState(), 0);
  assert.ok(ok(doc, 'p-alice'));
  assert.ok(ok(doc, 'p-bob'), 'absolute href on the platform host counts');
  assert.ok(!ok(doc, 'p-brand'), 'visible text "alice" but href /brand/');
  assert.ok(!ok(doc, 'p-ad'), 'sponsored');
  assert.ok(!ok(doc, 'p-celeb'), 'hashtag link skipped, author is celeb');
  assert.deepEqual([r.posts, r.okPosts, r.run], [5, 2, 1]);
});

test('feed: a reused post node with a new author loses its mark', () => {
  const c = compiled();
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  const fs = feedState();
  bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 0);
  doc.querySelector('#p-alice header a').setAttribute('href', '/stranger/');
  bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 0);
  assert.ok(!ok(doc, 'p-alice'));
});

test('feed filter works on the normal feed too (variant not needed)', () => {
  const c = compiled({ friends: ['alice'], toggles: { 'ig.forceFollowing': false } });
  const { window } = dom('ig-feed-friends.html', IG + '/');
  bz.runFriendsFeed(c, window.document, '/', window.location.href, feedState(), 0);
  assert.ok(ok(window.document, 'p-alice'));
  assert.ok(!ok(window.document, 'p-bob'));
});

test('stories tray: friends marked, order recorded for skipping', () => {
  const c = compiled();
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  const fs = feedState();
  bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 0);
  assert.ok(ok(doc, 'tray-alice'));
  assert.ok(ok(doc, 'tray-bob'));
  assert.ok(!ok(doc, 'tray-brand'));
  assert.ok(!ok(doc, 'tray-celeb'));
  assert.deepEqual(fs.trayOrder, ['alice', 'brand', 'bob.b', 'celeb']);
});

test('caught up after N hidden posts in a row: card after the last friend post, the rest hidden', () => {
  const c = compiled();
  c.friends.caughtUpAfter = 3;
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  const fs = feedState();
  let r = bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 0);
  assert.equal(r.caughtUp, false, 'run of 1 so far');
  const list = doc.getElementById('list');
  for (const id of ['s1', 's2']) {
    list.insertAdjacentHTML('beforeend', `<div class="row"><article id="${id}"><header><a href="/${id}/">x</a></header></article></div>`);
  }
  r = bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 10);
  assert.equal(r.caughtUp, true);
  const card = doc.querySelector('[data-bz="caughtup"]');
  assert.equal(card.textContent, 'Listo');
  assert.equal(card.previousElementSibling.querySelector('article').id, 'p-bob', 'right after the last friend post');
  assert.equal(doc.getElementById('loader').getAttribute('data-bz-hidden'), 'ig.caughtUp', 'loader below the list hidden');
  assert.equal(doc.getElementById('tabbar').getAttribute('data-bz-hidden'), null, 'never outside <main>');
  bz.removeCaughtUp(doc, fs);
  assert.equal(doc.querySelector('[data-bz="caughtup"]'), null);
  assert.equal(doc.getElementById('loader').getAttribute('data-bz-hidden'), null);
});

test('caught up when the feed stops growing and the last post is hidden', () => {
  const c = compiled();
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  const fs = feedState();
  bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 0);
  assert.equal(bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 3000).caughtUp, false);
  assert.equal(bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 4000).caughtUp, true);
});

test('not caught up while the last post is a friend\'s', () => {
  const c = compiled({ friends: ['celeb'] });
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const fs = feedState();
  bz.runFriendsFeed(c, window.document, '/', window.location.href, fs, 0);
  assert.equal(bz.runFriendsFeed(c, window.document, '/', window.location.href, fs, 60000).caughtUp, false);
});

test('story viewer: a friend\'s story is marked ok; a non-friend URL or author is a violation', () => {
  const c = compiled();
  const { window } = dom('ig-story.html', IG + '/stories/alice/1/');
  const doc = window.document;
  const root = doc.documentElement;
  assert.equal(bz.runFriendsStory(c, doc, '/stories/alice/1/', window.location.href), null);
  assert.equal(root.getAttribute('data-bz-story-ok'), '/stories/alice/1/');
  // The site swapped in another person's story without changing the URL yet.
  doc.getElementById('story-author').setAttribute('href', '/brand/');
  assert.deepEqual(bz.runFriendsStory(c, doc, '/stories/alice/1/', window.location.href), { user: 'alice', author: 'brand' });
  assert.equal(root.hasAttribute('data-bz-story-ok'), false, 'hidden again before the next frame');
  doc.getElementById('story-author').setAttribute('href', '/brand/');
  assert.deepEqual(bz.runFriendsStory(c, doc, '/stories/brand/2/', window.location.href), { user: 'brand', author: 'brand' });
  assert.equal(bz.runFriendsStory(c, doc, '/direct/inbox/', window.location.href), null);
  assert.equal(root.hasAttribute('data-bz-story-ok'), false, 'cleared off story routes');
});

test('highlights: decided by the author in the viewer; hidden until one is found', () => {
  const c = compiled();
  const { window } = dom('ig-story.html', IG + '/stories/highlights/9/');
  const doc = window.document;
  const path = '/stories/highlights/9/';
  assert.equal(bz.runFriendsStory(c, doc, path, window.location.href), null);
  assert.equal(doc.documentElement.getAttribute('data-bz-story-ok'), path, 'alice is a friend');
  doc.getElementById('story-author').setAttribute('href', '/celeb/');
  assert.deepEqual(bz.runFriendsStory(c, doc, path, window.location.href), { user: 'celeb', author: 'celeb' });
  doc.getElementById('story-author').remove();
  assert.equal(bz.runFriendsStory(c, doc, path, window.location.href), null);
  assert.equal(doc.documentElement.hasAttribute('data-bz-story-ok'), false, 'no author yet: stays hidden');
});

test('next friend story follows the tray order', () => {
  const f = compiled().friends;
  const order = ['alice', 'brand', 'bob.b', 'celeb'];
  assert.equal(bz.nextFriendStory(f, order, 'brand'), '/stories/bob.b/');
  assert.equal(bz.nextFriendStory(f, order, 'celeb'), null);
  assert.equal(bz.nextFriendStory(f, order, 'unknown'), '/stories/alice/');
  assert.equal(bz.nextFriendStory(f, [], 'brand'), null);
});

test('viewer advancing to a non-friend skips to the next friend in the tray, else closes', () => {
  const p = page('ig-feed-friends.html', IG + '/?variant=following');
  p.ctl.tick();   // sees the tray
  p.window.history.pushState({}, '', '/stories/alice/1/');
  assert.equal(p.window.location.pathname, '/stories/alice/1/', 'friend: allowed');
  p.window.history.pushState({}, '', '/stories/brand/2/');
  assert.deepEqual(p.nav.at(-1), ['replace', '/stories/bob.b/']);
  assert.equal(p.window.location.pathname, '/stories/alice/1/', 'the non-friend push never happened');
  p.window.history.pushState({}, '', '/stories/celeb/3/');
  assert.deepEqual(p.nav.at(-1), ['replace', '/?variant=following'], 'no friend after celeb: close');
  assert.ok(p.posts.some((m) => m.type === 'friends' && m.event === 'storySkipped'));
  assert.ok(p.posts.some((m) => m.type === 'friends' && m.event === 'storyClosed'));
});

test('a non-friend story loaded directly is caught at document start', () => {
  const p = page('ig-story.html', IG + '/stories/celeb/1/', { now: 5_000_000 });
  assert.ok(p.nav.length >= 1, 'redirected away at install');
  assert.equal(p.doc.documentElement.hasAttribute('data-bz-story-ok'), false);
  assert.match(p.doc.querySelector('style[data-bz]').textContent, /visibility:hidden/);
});

test('an unhooked URL change to a non-friend story is caught by the watchdog', () => {
  const p = page('ig-story.html', IG + '/stories/alice/1/');
  assert.equal(p.doc.documentElement.getAttribute('data-bz-story-ok'), '/stories/alice/1/');
  p.ctl.friendsState.trayOrder = ['alice', 'brand', 'bob.b'];
  // A router holding the original pushState (we can't see it) moves on.
  const raw = Object.getPrototypeOf(p.window.history).pushState;
  p.window.History.prototype.pushState = raw;
  raw.call(p.window.history, {}, '', '/stories/brand/2/');
  p.advance(3000);
  p.ctl.watchdog();
  assert.deepEqual(p.nav.at(-1), ['replace', '/stories/bob.b/']);
});

test('force Following: first load, logo tap and back go to ?variant=following, at most 3 times per 30 s', () => {
  const p = page('ig-feed-friends.html', IG + '/');
  assert.deepEqual(p.nav[0], ['replace', '/?variant=following'], 'full load of the plain feed');
  p.window.history.pushState({}, '', '/alice/');
  p.window.history.pushState({}, '', '/');
  assert.deepEqual(p.nav.at(-1), ['assign', '/?variant=following'], 'logo/home tap keeps history');
  p.window.history.pushState({}, '', '/');
  assert.equal(p.nav.length, 3);
  p.window.history.pushState({}, '', '/');
  assert.equal(p.nav.length, 3, 'gave up after 3 in 30 s');
  assert.ok(p.posts.some((m) => m.type === 'friends' && m.event === 'followingGaveUp'));
  assert.equal(p.window.location.pathname, '/', 'after giving up, the plain feed (still friends-only)');
  p.advance(31000);
  p.window.history.pushState({}, '', '/alice/');
  p.window.history.pushState({}, '', '/');
  assert.equal(p.nav.length, 4, 'tries again later');
});

test('force Following: the site tidying its own URL is left alone; other pages untouched', () => {
  const p = page('ig-feed-friends.html', IG + '/?variant=following');
  assert.equal(p.nav.length, 0);
  p.window.history.replaceState({}, '', '/');
  assert.equal(p.nav.length, 0, 'same page, variant dropped from the URL only');
  p.window.history.pushState({}, '', '/direct/inbox/');
  p.window.history.pushState({}, '', '/explore/search/');
  assert.equal(p.nav.length, 0);
});

test('force Following off: the plain feed stays, and is still friends-only', () => {
  const p = page('ig-feed-friends.html', IG + '/', { settings: { friends: ['alice'], toggles: { 'ig.forceFollowing': false } } });
  assert.equal(p.nav.length, 0);
  p.ctl.tick();
  assert.ok(ok(p.doc, 'p-alice'));
  assert.ok(!ok(p.doc, 'p-bob'));
});

test('canary: posts outside the post selector are blurred and reported', () => {
  const a = active('instagram', FRIENDS);
  a.recipe = Object.assign({}, a.recipe, { friendsFilter: Object.assign({}, a.recipe.friendsFilter, { post: 'main section.post' }) });
  const c = bz.compile(a);
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  const failed = bz.runFriendsCanaries(c, doc, '/', window.location.href);
  assert.deepEqual(failed, ['ig.canary.friendsPost']);
  assert.equal(doc.getElementById('p-brand').closest('[data-bz-blur]').getAttribute('data-bz-blur'), 'ig.canary.friendsPost');
  assert.equal(doc.getElementById('list').getAttribute('data-bz-blur'), null, 'never the whole list');
});

test('canary: a non-friend story link outside the tray selector is blurred', () => {
  const a = active('instagram', FRIENDS);
  a.recipe = Object.assign({}, a.recipe, { friendsFilter: Object.assign({}, a.recipe.friendsFilter, { storyTray: 'li.tray a' }) });
  const c = bz.compile(a);
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  assert.deepEqual(bz.runFriendsCanaries(c, doc, '/', window.location.href), ['ig.canary.friendsStory']);
  assert.equal(doc.getElementById('tray-brand').getAttribute('data-bz-blur'), 'ig.canary.friendsStory');
  assert.equal(doc.getElementById('tray-alice').getAttribute('data-bz-blur'), null);
});

test('canaries stay quiet on a healthy feed and off the feed', () => {
  const c = compiled();
  const { window } = dom('ig-feed-friends.html', IG + '/');
  assert.deepEqual(bz.runFriendsCanaries(c, window.document, '/', window.location.href), []);
  assert.deepEqual(bz.runFriendsCanaries(c, window.document, '/stranger/', window.location.href), []);
});

test('installed page: overlay when a friends canary fails', () => {
  const p = page('ig-feed-friends.html', IG + '/?variant=following');
  p.doc.getElementById('p-brand').outerHTML = '<div id="loose"><a href="/brand/">b</a><a href="/p/Z9/">p</a></div>';
  p.ctl.tick();
  assert.ok(p.posts.some((m) => m.type === 'canary' && m.ids.includes('ig.canary.friendsPost')));
  assert.ok(p.doc.querySelector('[data-bz="overlay"]'));
});

test('scan: own Followers page, profile links on screen only, deduplicated', () => {
  const c = compiled({});
  const { window } = dom('ig-followers.html', IG + '/me/followers/');
  const sent = {};
  const r = bz.runScan(c, window.document, '/me/followers/', window.location.href, sent);
  assert.deepEqual(r, { list: 'followers', owner: 'me', usernames: ['alice', 'bob.b', 'brand'] });
  assert.deepEqual(bz.runScan(c, window.document, '/me/followers/', window.location.href, sent).usernames, []);
  assert.equal(bz.runScan(c, window.document, '/me/', window.location.href, {}), null, 'only list routes');
});

test('scan: Close Friends reads checked rows only', () => {
  const c = compiled({});
  const { window } = dom('ig-close-friends.html', IG + '/accounts/close_friends/');
  const r = bz.runScan(c, window.document, '/accounts/close_friends/', window.location.href, {});
  assert.deepEqual(r, { list: 'closeFriends', owner: null, usernames: ['alice', 'carol'] });
  const { window: w2 } = dom('ig-followers.html', IG + '/accounts/close_friends/');
  assert.equal(bz.runScan(c, w2.document, '/accounts/close_friends/', w2.location.href, {}).noCheckboxes, true);
});

test('scan only runs while native armed it, and never touches the page', () => {
  const off = page('ig-followers.html', IG + '/me/following/', { settings: {} });
  off.ctl.tick();
  assert.ok(!off.posts.some((m) => m.type === 'friendsScan'));
  const on = page('ig-followers.html', IG + '/me/following/', { settings: {}, scan: true });
  const html = () => on.doc.body.innerHTML.replace(/ data-bz-hidden="[^"]*"/g, '');
  const before = html();
  on.ctl.tick();
  const msg = on.posts.find((m) => m.type === 'friendsScan');
  assert.deepEqual(msg, { type: 'friendsScan', list: 'following', owner: 'me', usernames: ['alice', 'bob.b', 'brand'] });
  assert.equal(html(), before, 'read-only (apart from the usual Explore-link heuristic)');
  assert.equal(on.nav.length, 0, 'no navigation, no requests');
});

test('allow zones and profiles are untouched while Old Instagram is on', () => {
  const thread = page('ig-thread.html', IG + '/direct/t/123/');
  thread.ctl.tick();
  assert.equal(thread.doc.querySelectorAll('[data-bz-hidden],[data-bz-blur],[data-bz-fr]').length, 0);
  assert.equal(thread.nav.length, 0);
  const profile = page('ig-profile.html', IG + '/stranger/');
  profile.ctl.tick();
  assert.equal(profile.nav.length, 0, "a non-friend's profile opens");
  assert.doesNotMatch(profile.doc.querySelector('style[data-bz]').textContent, /data-bz-fr/);
});
