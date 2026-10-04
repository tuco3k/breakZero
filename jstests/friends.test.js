'use strict';
// Feed rules (ARCHITECTURE.md §4c rev. 2): feed and stories filtered by rule (mutuals by default),
// never/always lists, profile stories, one-tap hide, hidden report, caught up, forced Following,
// manual scan, auto-scroll sync and its stop conditions, canaries. Usernames come from hrefs only.
const test = require('node:test');
const assert = require('node:assert/strict');
const { bz, active, dom } = require('./helpers');

const IG = 'https://www.instagram.com';
// Mutuals: alice, bob.b, carol. Following only: brand, celeb. Follower only: fan.
const PEOPLE = {
  followers: ['alice', 'bob.b', 'carol', 'fan'],
  following: ['alice', 'bob.b', 'carol', 'brand', 'celeb']
};
const ok = (doc, id) => doc.getElementById(id).getAttribute('data-bz-fr') === 'ok';

function compiled(settings = {}, people = PEOPLE) {
  return bz.compile(active('instagram', settings, true, 'togglesDecide', people));
}

function feedState() {
  return { postCount: -1, lastNewPostAt: 0, trayOrder: [], card: null, cardHref: null, caughtUpText: 'Listo' };
}

/* A live page with the script installed; navigation and timers are recorded, not performed. */
function page(fixture, url, opts = {}) {
  const { window } = dom(fixture, url);
  const posts = [];
  const nav = [];
  const timers = [];
  window.webkit = { messageHandlers: { bz: { postMessage: (m) => posts.push(m) } } };
  let now = opts.now || 1_000_000;
  const scrolls = [];
  const ctl = bz.install(window, {
    active: active('instagram', opts.settings || {}, true, 'togglesDecide', opts.people === undefined ? PEOPLE : opts.people),
    state: opts.state || { grant: null },
    strings: { needsUpdate: 'x', report: 'y', caughtUp: 'Listo', hide: 'Ocultar' },
    limits: { blocked: null },
    scan: !!opts.scan,
    sync: opts.sync || null
  }, {
    replace: (u) => nav.push(['replace', u]),
    assign: (u) => nav.push(['assign', u]),
    setInterval: () => 0,
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    clearTimeout: (id) => { if (timers[id - 1]) timers[id - 1].cancelled = true; },
    now: () => now,
    random: () => 0.5,
    scrollOnce: () => { scrolls.push(1); return { atBottom: !!opts.atBottom && opts.atBottom() }; }
  });
  /* Run the most recent pending timer (the auto-scroll's next step). */
  function step() {
    const t = timers.filter((x) => !x.cancelled && !x.ran).at(-1);
    if (!t) return false;
    t.ran = true;
    t.fn();
    return true;
  }
  return { window, doc: window.document, posts, nav, ctl, timers, scrolls, step, advance: (ms) => { now += ms; } };
}

const sent = (p, type) => p.posts.filter((m) => m.type === type);

// ------------------------------------------------------------------ rules

test('no data and no never list: nothing to filter, no friends CSS; the collectors still exist', () => {
  const c = bz.compile(active('instagram'));
  assert.equal(c.friends, null);
  assert.doesNotMatch(bz.cssFor(c, '/'), /data-bz-fr/);
  assert.ok(c.scan);
});

test('feed CSS: default deny for posts and tray items, only on the feed', () => {
  const c = compiled();
  const css = bz.cssFor(c, '/');
  assert.match(css, /:is\(main article, main \[role="article"\],\[data-bz-post\]\):not\(\[data-bz-fr="ok"\]\)\{display:none!important\}/);
  assert.match(css, /:is\(a\[href\^="\/stories\/"\]\):not\(\[data-bz-fr="ok"\]\)\{display:none!important\}/);
  assert.doesNotMatch(bz.cssFor(c, '/stranger/'), /data-bz-fr/, 'profiles you open are untouched');
  assert.equal(bz.cssFor(c, '/direct/t/1/'), '', 'DMs are an allow zone');
  assert.match(bz.cssFor(c, '/stories/alice/1/'), /html:not\(\[data-bz-story-ok\]\) body\{visibility:hidden!important\}/);
});

test('feed, mutuals (default): mutuals shown; following-only, ads and strangers hidden; author from href', () => {
  const c = compiled();
  const { window } = dom('ig-feed-friends.html', IG + '/?variant=following');
  const doc = window.document;
  const r = bz.runFriendsFeed(c, doc, '/', window.location.href, feedState(), 0);
  assert.ok(ok(doc, 'p-alice'));
  assert.ok(ok(doc, 'p-bob'));
  assert.ok(!ok(doc, 'p-brand'), 'I follow brand, brand doesn\'t follow me; visible text says "alice"');
  assert.ok(!ok(doc, 'p-ad'));
  assert.ok(!ok(doc, 'p-celeb'));
  assert.deepEqual(r.hidden.sort(), ['brand', 'celeb', 'shoe_co']);
});

test('feed rules by audience: everyone I follow, my list, close friends', () => {
  const run = (settings, people = PEOPLE) => {
    const { window } = dom('ig-feed-friends.html', IG + '/');
    bz.runFriendsFeed(compiled(settings, people), window.document, '/', window.location.href, feedState(), 0);
    return ['p-alice', 'p-brand', 'p-ad', 'p-bob', 'p-celeb'].filter((id) => ok(window.document, id));
  };
  assert.deepEqual(run({ feedRules: { feed: 'everyone' } }), ['p-alice', 'p-brand', 'p-bob', 'p-celeb']);
  assert.deepEqual(run({ feedRules: { feed: 'myList' }, friends: ['celeb'] }), ['p-celeb']);
  assert.deepEqual(run({ feedRules: { feed: 'closeFriends' } }, Object.assign({ closeFriends: ['bob.b'] }, PEOPLE)), ['p-bob']);
});

test('precedence: never beats always beats the rule', () => {
  const c = compiled({ feedRules: { always: ['celeb', 'alice'], never: ['alice'] } });
  const { window } = dom('ig-feed-friends.html', IG + '/');
  bz.runFriendsFeed(c, window.document, '/', window.location.href, feedState(), 0);
  assert.ok(!ok(window.document, 'p-alice'), 'never-shown even though always-shown and mutual');
  assert.ok(ok(window.document, 'p-celeb'), 'always-shown although not mutual');
  assert.ok(ok(window.document, 'p-bob'));
});

test('never-show works before any data exists', () => {
  const c = compiled({ feedRules: { never: ['brand'] } }, null);
  const { window } = dom('ig-feed-friends.html', IG + '/');
  bz.runFriendsFeed(c, window.document, '/', window.location.href, feedState(), 0);
  assert.ok(!ok(window.document, 'p-brand'));
  assert.ok(ok(window.document, 'p-celeb'), 'no audience filter without data');
});

test('a reused post node with a new author loses its mark', () => {
  const c = compiled();
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  const fs = feedState();
  bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 0);
  doc.querySelector('#p-alice header a').setAttribute('href', '/stranger/');
  bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 0);
  assert.ok(!ok(doc, 'p-alice'));
});

test('stories tray follows the stories rule; order recorded for skipping', () => {
  const c = compiled({ feedRules: { stories: 'everyone' } });
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  const fs = feedState();
  bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 0);
  assert.ok(ok(doc, 'tray-alice') && ok(doc, 'tray-brand') && ok(doc, 'tray-bob') && ok(doc, 'tray-celeb'));
  const m = compiled();
  bz.runFriendsFeed(m, doc, '/', window.location.href, fs, 0);
  assert.ok(ok(doc, 'tray-alice') && ok(doc, 'tray-bob'));
  assert.ok(!ok(doc, 'tray-brand') && !ok(doc, 'tray-celeb'));
  assert.deepEqual(fs.trayOrder, ['alice', 'brand', 'bob.b', 'celeb']);
});

// ------------------------------------------------------------------ one-tap hide and report

test('one-tap hide: shown posts get our button; tapping it hides the author at once and tells native', () => {
  const p = page('ig-feed-friends.html', IG + '/?variant=following');
  p.ctl.tick();
  const btn = p.doc.querySelector('#p-alice [data-bz="hidewrap"] button');
  assert.ok(btn, 'button on a shown post');
  assert.equal(btn.getAttribute('aria-label'), 'Ocultar @alice');
  assert.equal(p.doc.querySelector('#p-brand [data-bz="hidewrap"]'), null, 'not on hidden posts');
  assert.equal(p.doc.querySelector('#p-alice').firstElementChild.getAttribute('data-bz'), 'hidewrap', 'our own wrapper, first child');
  btn.click();
  assert.deepEqual(sent(p, 'hideAccount'), [{ type: 'hideAccount', username: 'alice' }]);
  p.ctl.tick();
  assert.ok(!ok(p.doc, 'p-alice'), 'hidden right away');
  assert.ok(ok(p.doc, 'p-bob'));
});

test('hidden authors are reported once each, for the status pill', () => {
  const p = page('ig-feed-friends.html', IG + '/?variant=following');
  p.ctl.tick();
  p.ctl.tick();
  const reports = sent(p, 'friendsHidden');
  assert.equal(reports.length, 1);
  assert.deepEqual(reports[0].usernames.sort(), ['brand', 'celeb', 'shoe_co']);
});

// ------------------------------------------------------------------ caught up

test('caught up after N hidden posts in a row: card after the last shown post, the rest hidden', () => {
  const c = compiled();
  c.friends.caughtUpAfter = 3;
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  const fs = feedState();
  assert.equal(bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 0).caughtUp, false);
  const list = doc.getElementById('list');
  for (const id of ['s1', 's2']) {
    list.insertAdjacentHTML('beforeend', `<div class="row"><article id="${id}"><header><a href="/${id}/">x</a></header></article></div>`);
  }
  assert.equal(bz.runFriendsFeed(c, doc, '/', window.location.href, fs, 10).caughtUp, true);
  const card = doc.querySelector('[data-bz="caughtup"]');
  assert.equal(card.textContent, 'Listo');
  assert.equal(card.previousElementSibling.querySelector('article').id, 'p-bob');
  assert.equal(doc.getElementById('loader').getAttribute('data-bz-hidden'), 'ig.caughtUp');
  assert.equal(doc.getElementById('tabbar').getAttribute('data-bz-hidden'), null, 'never outside <main>');
  bz.removeCaughtUp(doc, fs);
  assert.equal(doc.querySelector('[data-bz="caughtup"]'), null);
});

test('caught up when the feed stops growing and the last post is hidden', () => {
  const c = compiled();
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const fs = feedState();
  bz.runFriendsFeed(c, window.document, '/', window.location.href, fs, 0);
  assert.equal(bz.runFriendsFeed(c, window.document, '/', window.location.href, fs, 3000).caughtUp, false);
  assert.equal(bz.runFriendsFeed(c, window.document, '/', window.location.href, fs, 4000).caughtUp, true);
});

// ------------------------------------------------------------------ stories

test('story viewer: an allowed story is marked ok; a hidden URL user or author is a violation', () => {
  const c = compiled();
  const { window } = dom('ig-story.html', IG + '/stories/alice/1/');
  const doc = window.document;
  const root = doc.documentElement;
  assert.equal(bz.runFriendsStory(c, doc, '/stories/alice/1/', window.location.href), null);
  assert.equal(root.getAttribute('data-bz-story-ok'), '/stories/alice/1/');
  doc.getElementById('story-author').setAttribute('href', '/brand/');
  assert.deepEqual(bz.runFriendsStory(c, doc, '/stories/alice/1/', window.location.href),
    { user: 'alice', author: 'brand', back: null });
  assert.equal(root.hasAttribute('data-bz-story-ok'), false, 'hidden again before the next frame');
});

test('story viewer: a story opened from that person\'s profile passes; someone else goes back to that profile', () => {
  const c = compiled();
  const { window } = dom('ig-story.html', IG + '/stories/brand/1/');
  const doc = window.document;
  doc.getElementById('story-author').setAttribute('href', '/brand/');
  assert.equal(bz.runFriendsStory(c, doc, '/stories/brand/1/', window.location.href, { storyUser: 'brand' }), null);
  doc.getElementById('story-author').setAttribute('href', '/celeb/');
  assert.deepEqual(bz.runFriendsStory(c, doc, '/stories/brand/1/', window.location.href, { storyUser: 'brand' }),
    { user: 'brand', author: 'celeb', back: '/brand/' });
});

test('highlights: decided by the author; from that person\'s profile they play (profile stories on)', () => {
  const c = compiled();
  const { window } = dom('ig-story.html', IG + '/stories/highlights/9/');
  const doc = window.document;
  const path = '/stories/highlights/9/';
  assert.equal(bz.runFriendsStory(c, doc, path, window.location.href), null, 'alice is mutual');
  doc.getElementById('story-author').setAttribute('href', '/celeb/');
  assert.deepEqual(bz.runFriendsStory(c, doc, path, window.location.href), { user: 'celeb', author: 'celeb', back: null });
  assert.equal(bz.runFriendsStory(c, doc, path, window.location.href, { highlightFrom: 'celeb' }), null);
  const off = compiled({ feedRules: { profileStories: false } });
  assert.deepEqual(bz.runFriendsStory(off, doc, path, window.location.href, { highlightFrom: 'celeb' }),
    { user: 'celeb', author: 'celeb', back: '/celeb/' }, 'off: back to their profile');
});

test('profile stories ON: tap a non-mutual\'s ring on their profile, it plays; the viewer can\'t move on to others', () => {
  const p = page('ig-profile.html', IG + '/brand/');
  p.window.history.pushState({}, '', '/stories/brand/1/');
  assert.equal(p.window.location.pathname, '/stories/brand/1/', 'plays');
  assert.equal(p.nav.length, 0);
  p.window.history.replaceState({}, '', '/stories/brand/2/');
  assert.equal(p.window.location.pathname, '/stories/brand/2/', 'their next story too');
  p.window.history.pushState({}, '', '/stories/alice/3/');
  assert.deepEqual(p.nav.at(-1), ['replace', '/brand/'], 'no auto-advance into others, even allowed ones');
});

test('profile stories OFF: tapping the ring keeps you on their profile, no reload, with a message', () => {
  const p = page('ig-profile.html', IG + '/brand/', { settings: { feedRules: { profileStories: false } } });
  p.window.history.pushState({}, '', '/stories/brand/1/');
  assert.equal(p.window.location.pathname, '/brand/', 'stayed');
  assert.equal(p.nav.length, 0, 'never bounced to the feed, not even reloaded');
  assert.ok(p.posts.some((m) => m.type === 'redirect' && m.ruleID === bz.GATE_ID && m.reason === 'bounced'));
});

test('never-show: their profile opens, their story doesn\'t', () => {
  const p = page('ig-profile.html', IG + '/alice/', { settings: { feedRules: { never: ['alice'] } } });
  p.window.history.pushState({}, '', '/stories/alice/1/');
  assert.equal(p.window.location.pathname, '/alice/');
  assert.equal(p.nav.length, 0);
});

test('from the feed: a hidden story skips to the next allowed one in the tray, else closes', () => {
  const p = page('ig-feed-friends.html', IG + '/?variant=following');
  p.ctl.tick();
  p.window.history.pushState({}, '', '/stories/alice/1/');
  assert.equal(p.window.location.pathname, '/stories/alice/1/');
  p.window.history.pushState({}, '', '/stories/brand/2/');
  assert.deepEqual(p.nav.at(-1), ['replace', '/stories/bob.b/']);
  p.window.history.pushState({}, '', '/stories/celeb/3/');
  assert.deepEqual(p.nav.at(-1), ['replace', '/?variant=following'], 'nobody allowed after celeb: close');
});

test('feed → story: the feed still in the DOM (hidden posts\' headers) is never read as the story\'s author', () => {
  const p = page('ig-feed-friends.html', IG + '/?variant=following');
  p.ctl.tick();
  p.doc.querySelector('#p-alice').insertAdjacentHTML('afterbegin', '<section><header><a href="/brand/">b</a></header></section>');
  p.window.history.pushState({}, '', '/stories/bob.b/1/');
  assert.equal(p.window.location.pathname, '/stories/bob.b/1/');
  assert.equal(p.nav.length, 0, 'no false skip');
  assert.equal(p.doc.documentElement.getAttribute('data-bz-story-ok'), '/stories/bob.b/1/');
});

test('a hidden story loaded directly is caught at document start', () => {
  const p = page('ig-story.html', IG + '/stories/celeb/1/');
  assert.ok(p.nav.length >= 1);
  assert.equal(p.doc.documentElement.hasAttribute('data-bz-story-ok'), false);
});

test('an unhooked URL change to a hidden story is caught by the watchdog', () => {
  const p = page('ig-story.html', IG + '/stories/alice/1/');
  p.ctl.friendsState.trayOrder = ['alice', 'brand', 'bob.b'];
  const raw = Object.getPrototypeOf(p.window.history).pushState;
  p.window.History.prototype.pushState = raw;
  raw.call(p.window.history, {}, '', '/stories/brand/2/');
  p.advance(3000);
  p.ctl.watchdog();
  assert.deepEqual(p.nav.at(-1), ['replace', '/stories/bob.b/']);
});

// ------------------------------------------------------------------ Following feed

test('force Following: first load, logo tap and back go to ?variant=following, at most 3 times per 30 s', () => {
  const p = page('ig-feed-friends.html', IG + '/');
  assert.deepEqual(p.nav[0], ['replace', '/?variant=following']);
  p.window.history.pushState({}, '', '/alice/');
  p.window.history.pushState({}, '', '/');
  assert.deepEqual(p.nav.at(-1), ['assign', '/?variant=following']);
  p.window.history.pushState({}, '', '/');
  p.window.history.pushState({}, '', '/');
  assert.equal(p.nav.length, 3, 'gave up after 3 in 30 s');
  assert.ok(p.posts.some((m) => m.type === 'friends' && m.event === 'followingGaveUp'));
});

test('force Following: the site tidying its own URL is left alone', () => {
  const p = page('ig-feed-friends.html', IG + '/?variant=following');
  p.window.history.replaceState({}, '', '/');
  assert.equal(p.nav.length, 0);
});

// ------------------------------------------------------------------ canaries

test('canary: posts outside the post selector are blurred and reported', () => {
  const a = active('instagram', {}, true, 'togglesDecide', PEOPLE);
  a.recipe = Object.assign({}, a.recipe, { friendsFilter: Object.assign({}, a.recipe.friendsFilter, { post: 'main section.post' }) });
  const c = bz.compile(a);
  const { window } = dom('ig-feed-friends.html', IG + '/');
  assert.deepEqual(bz.runFriendsCanaries(c, window.document, '/', window.location.href), ['ig.canary.friendsPost']);
});

test('canary: a hidden person\'s story link outside the tray selector is blurred', () => {
  const a = active('instagram', {}, true, 'togglesDecide', PEOPLE);
  a.recipe = Object.assign({}, a.recipe, { friendsFilter: Object.assign({}, a.recipe.friendsFilter, { storyTray: 'li.tray a' }) });
  const c = bz.compile(a);
  const { window } = dom('ig-feed-friends.html', IG + '/');
  const doc = window.document;
  assert.deepEqual(bz.runFriendsCanaries(c, doc, '/', window.location.href), ['ig.canary.friendsStory']);
  assert.equal(doc.getElementById('tray-brand').getAttribute('data-bz-blur'), 'ig.canary.friendsStory');
  assert.equal(doc.getElementById('tray-alice').getAttribute('data-bz-blur'), null);
});

// ------------------------------------------------------------------ manual scan

test('manual scan: own Followers page, profile links on screen only, deduplicated', () => {
  const c = compiled({}, null);
  const { window } = dom('ig-followers.html', IG + '/me/followers/');
  const s = {};
  assert.deepEqual(bz.runScan(c, window.document, '/me/followers/', window.location.href, s),
    { list: 'followers', owner: 'me', usernames: ['alice', 'bob.b', 'brand'] });
  assert.deepEqual(bz.runScan(c, window.document, '/me/followers/', window.location.href, s).usernames, []);
  assert.equal(bz.runScan(c, window.document, '/me/followers/', window.location.href, {}, 'following'), null, 'only that list');
});

test('Close Friends page: checked rows only', () => {
  const c = compiled({}, null);
  const { window } = dom('ig-close-friends.html', IG + '/accounts/close_friends/');
  assert.deepEqual(bz.runScan(c, window.document, '/accounts/close_friends/', window.location.href, {}),
    { list: 'closeFriends', owner: null, usernames: ['alice', 'carol'] });
});

// ------------------------------------------------------------------ auto-scroll sync

const SYNC = { list: 'followers', owner: 'me', pacing: { minStep: 2, maxStep: 4, pauseEvery: 3, minPause: 8, maxPause: 15 } };

test('auto-scroll: reads names as it scrolls, at native\'s pace, then reports the end', () => {
  let bottom = false;
  const p = page('ig-followers.html', IG + '/me/followers/', { people: null, sync: SYNC, atBottom: () => bottom });
  assert.equal(p.timers.length, 1);
  assert.equal(p.timers[0].ms, 3000, 'first step after 2–4 s');
  p.step();
  assert.deepEqual(sent(p, 'friendsScan'), [{ type: 'friendsScan', list: 'followers', owner: 'me', usernames: ['alice', 'bob.b', 'brand'] }]);
  assert.equal(p.scrolls.length, 1, 'one screen');
  p.doc.getElementById('list').insertAdjacentHTML('beforeend', '<li><a href="/dave/">dave</a></li>');
  p.step();
  assert.deepEqual(sent(p, 'friendsScan').at(-1).usernames, ['dave'], 'only new names');
  p.step();
  assert.equal(p.timers.at(-1).ms, 11500, 'a longer pause every 3 screens');
  bottom = true;
  for (let i = 0; i < 5; i++) p.step();
  assert.deepEqual(sent(p, 'syncEvent'), [{ type: 'syncEvent', list: 'followers', event: 'end' }]);
  assert.equal(p.ctl.sync, null);
  assert.equal(p.step(), false, 'stopped scrolling');
});

test('auto-scroll: nothing new away from the bottom is a stall', () => {
  const p = page('ig-followers.html', IG + '/me/followers/', { people: null, sync: SYNC, atBottom: () => false });
  for (let i = 0; i < 6; i++) p.step();
  assert.deepEqual(sent(p, 'syncEvent').at(-1), { type: 'syncEvent', list: 'followers', event: 'stalled' });
});

test('auto-scroll stops at once on a warning dialog, a challenge, a login page or leaving the list', () => {
  const warn = page('ig-followers.html', IG + '/me/followers/', { people: null, sync: SYNC });
  warn.doc.body.insertAdjacentHTML('beforeend', '<div role="dialog"><p>Try Again Later</p><button>OK</button></div>');
  const scrolled = warn.scrolls.length;
  warn.step();
  assert.deepEqual(sent(warn, 'syncEvent'), [{ type: 'syncEvent', list: 'followers', event: 'warning' }]);
  assert.equal(warn.scrolls.length, scrolled, 'no further scrolling');
  assert.equal(sent(warn, 'friendsScan').length, 0);

  const ch = page('ig-followers.html', IG + '/me/followers/', { people: null, sync: SYNC });
  ch.window.history.pushState({}, '', '/challenge/action/');
  ch.step();
  assert.equal(sent(ch, 'syncEvent')[0].event, 'challenge');

  const login = page('ig-followers.html', IG + '/me/followers/', { people: null, sync: SYNC });
  login.window.history.pushState({}, '', '/accounts/login/');
  login.step();
  assert.equal(sent(login, 'syncEvent')[0].event, 'login');

  const left = page('ig-followers.html', IG + '/me/followers/', { people: null, sync: SYNC });
  left.window.history.pushState({}, '', '/direct/inbox/');
  left.step();
  assert.equal(sent(left, 'syncEvent')[0].event, 'leftPage');
});

test('auto-scroll: a dialog that is the list itself is fine (desktop-style followers dialog)', () => {
  const p = page('ig-followers.html', IG + '/me/followers/', { people: null, sync: SYNC });
  p.doc.getElementById('list').setAttribute('role', 'dialog');
  p.step();
  assert.equal(sent(p, 'syncEvent').length, 0);
  assert.equal(sent(p, 'friendsScan').length, 1);
});

test('auto-scroll: native stopping it (cap reached) cancels the next step', () => {
  const p = page('ig-followers.html', IG + '/me/followers/', { people: null, sync: SYNC });
  p.window.__bzUpdate({ sync: null });
  assert.equal(p.ctl.sync, null);
  assert.equal(p.step(), false);
});

test('auto-scroll pacing stays within native\'s bounds', () => {
  const pace = SYNC.pacing;
  assert.equal(bz.syncDelay(pace, 1, 0), 2000);
  assert.equal(bz.syncDelay(pace, 1, 0.999), 3998);
  assert.equal(bz.syncDelay(pace, 3, 0), 8000);
  assert.equal(bz.syncDelay(pace, 6, 0.999), 14993);
});

test('auto-scroll warning detection is structural, not text', () => {
  const c = compiled({}, null);
  const { window } = dom('ig-followers.html', IG + '/me/followers/');
  assert.equal(bz.syncWarning(c, window.document, '/me/followers/', window.location.href), null);
  window.document.body.insertAdjacentHTML('beforeend', '<div role="alertdialog"></div>');
  assert.equal(bz.syncWarning(c, window.document, '/me/followers/', window.location.href), 'warning');
  assert.equal(bz.syncWarning(c, window.document, '/checkpoint/', window.location.href), 'challenge');
});

// ------------------------------------------------------------------ untouched surfaces

test('allow zones and profiles are untouched while feed rules are on', () => {
  const thread = page('ig-thread.html', IG + '/direct/t/123/');
  thread.ctl.tick();
  assert.equal(thread.doc.querySelectorAll('[data-bz-hidden],[data-bz-blur],[data-bz-fr],[data-bz="hidewrap"]').length, 0);
  assert.equal(thread.nav.length, 0);
  const profile = page('ig-profile.html', IG + '/stranger/');
  profile.ctl.tick();
  assert.equal(profile.nav.length, 0, "a non-mutual's profile opens");
  assert.doesNotMatch(profile.doc.querySelector('style[data-bz]').textContent, /data-bz-fr/);
});

// ------------------------------------------------------------------ search modes (QUESTIONS #58–60)

test('search Normal: results show everyone; the post/reel grid on the search page is hidden', () => {
  const c = compiled();
  const { window } = dom('ig-search.html', IG + '/explore/search/');
  const doc = window.document;
  bz.runHeuristics(c, doc, '/explore/search/', window.location.href, () => {});
  bz.runSearchFilter(c, doc, '/explore/search/', window.location.href);
  const hiddenEl = (id) => doc.getElementById(id).closest('[data-bz-hidden]') !== null;
  assert.ok(!hiddenEl('row-alice') && !hiddenEl('row-brand') && !hiddenEl('row-fan'), 'all accounts');
  assert.ok(hiddenEl('grid-post') && hiddenEl('grid-reel'), 'no Explore grid');
  assert.ok(!hiddenEl('tab-search'), 'the search entry stays');
  assert.deepEqual(bz.runCanaries(c, doc, '/explore/search/', window.location.href, () => {}), []);
});

test('search Only matching: rows for accounts the feed rule hides are hidden; re-shown when allowed', () => {
  const c = compiled({ searchMode: 'matching' });
  const { window } = dom('ig-search.html', IG + '/explore/search/');
  const doc = window.document;
  assert.equal(bz.runSearchFilter(c, doc, '/explore/search/', window.location.href), 2);
  const rowHidden = (id) => doc.getElementById(id).getAttribute('data-bz-hidden') === 'ig.search.match';
  assert.ok(!rowHidden('row-alice'), 'mutual');
  assert.ok(rowHidden('row-brand'), 'following only');
  assert.ok(rowHidden('row-fan'), 'follower only');
  assert.ok(!rowHidden('row-tag'), 'not an account');
  const wider = compiled({ searchMode: 'matching', feedRules: { feed: 'everyone' } });
  bz.runSearchFilter(wider, doc, '/explore/search/', window.location.href);
  assert.ok(!rowHidden('row-brand'), 'now allowed: shown again');
  assert.equal(bz.runSearchFilter(c, doc, '/direct/inbox/', window.location.href), 0, 'search pages only');
});

test('search Only matching without mutuals data hides nothing', () => {
  const c = compiled({ searchMode: 'matching' }, null);
  const { window } = dom('ig-search.html', IG + '/explore/search/');
  assert.equal(bz.runSearchFilter(c, window.document, '/explore/search/', window.location.href), 0);
});
