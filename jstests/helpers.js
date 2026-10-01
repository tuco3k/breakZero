'use strict';
// Shared test helpers. Mirrors ActiveRecipe (Core/ActiveRecipe.swift) for building the
// config native code passes to the script.
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const KIT = path.join(__dirname, '..', 'Packages', 'BreakZeroKit');
const SCRIPT = path.join(KIT, 'Sources', 'LiteWeb', 'Resources', 'Scripts', 'bz-filter.js');
const bz = require(SCRIPT);

function recipe(platform) {
  return JSON.parse(fs.readFileSync(path.join(KIT, 'Sources', 'Core', 'Resources', 'Recipes', platform + '.json'), 'utf8'));
}

function active(platform, settings = {}, signedIn = true, shortForm = 'togglesDecide') {
  const r = recipe(platform);
  const toggles = settings.toggles || {};
  const setting = (t) => (t in toggles ? toggles[t] : (r.toggles.find((x) => x.id === t) || { defaultOn: true }).defaultOn);
  // Mirrors PlatformSettings.friendsActive + ActiveRecipe: forced toggles while Old Instagram is active.
  const ff = r.friendsFilter;
  const friends = settings.friends || [];
  const friendsActive = !!ff && friends.length > 0 && setting(ff.toggle);
  const forced = new Set(friendsActive ? ff.forcedToggles || [] : []);
  const on = (t) => forced.has(t) || setting(t);
  // Mirrors ActiveRecipe.init(shortForm:).
  const keepRule = (x) => {
    if (!x.shortForm) return on(x.toggle);
    if (shortForm === 'budgetAllowed') return false;
    if (shortForm === 'forcedBlocked') return true;
    return on(x.toggle);
  };
  const keep = (list) => (list || []).filter(keepRule);
  let gate = [];
  let activeFriends;
  if (friendsActive) {
    const force = ff.forceFollowingToggle ? on(ff.forceFollowingToggle) : false;
    gate = [storyGateRule(friends, ff, force)];
    activeFriends = { usernames: friends, forceFollowing: force };
  }
  const out = Object.assign({}, r, {
    routes: (settings.customBlocks || []).map((p, i) => ({
      id: 'custom.block.' + i, toggle: 'custom', pattern: p.startsWith('^') ? p : '^' + p, action: 'block'
    })).concat(gate, keep(r.routes)),
    hide: keep(r.hide).concat((settings.customHides || []).map((s, i) => ({ id: 'custom.hide.' + i, toggle: 'custom', selector: s }))),
    heuristics: keep(r.heuristics),
    behaviors: (r.behaviors || []).filter((x) => on(x.toggle)),
    canaries: keep(r.canaries),
    resourceBlocks: keep(r.resourceBlocks)
  });
  let landingKey = settings.landing && r.landing.options[settings.landing] ? settings.landing : r.landing.default;
  if (!signedIn && r.landing.signedOut && r.landing.options[r.landing.signedOut]) landingKey = r.landing.signedOut;
  const result = { recipe: out, landingPath: r.landing.options[landingKey], shortForm };
  if (activeFriends) result.friends = activeFriends;
  return result;
}

// Mirrors Friends.storyGatePattern / storyGateRule (Core/Friends.swift).
function storyGateRule(friends, ff, forceFollowing) {
  const names = friends.concat(ff.storyExempt || []).sort().map((n) => n.split('.').join('\\.'));
  const to = forceFollowing && ff.followingQuery ? ff.feedPath + '?' + ff.followingQuery : ff.feedPath;
  return {
    id: 'ig.friends.storyGate', toggle: ff.toggle, action: 'redirect', to,
    pattern: '^/stories/(?!(?:' + names.join('|') + ')(?:/|$))[^/]+(?:/|$)'
  };
}

function dom(fixture, url) {
  const html = fs.readFileSync(path.join(__dirname, 'fixtures', fixture), 'utf8');
  return new JSDOM(html, { url, pretendToBeVisual: true });
}

module.exports = { bz, recipe, active, dom, storyGateRule, KIT, SCRIPT };
