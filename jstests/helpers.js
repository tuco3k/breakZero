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

function active(platform, settings = {}, signedIn = true, shortForm = 'togglesDecide', people = null) {
  const r = recipe(platform);
  const toggles = settings.toggles || {};
  const setting = (t) => (t in toggles ? toggles[t] : (r.toggles.find((x) => x.id === t) || { defaultOn: true }).defaultOn);
  // Mirrors PlatformSettings.feedRulesOn + ActiveRecipe: forced toggles while feed rules are on.
  const ff = r.friendsFilter;
  const friends = settings.friends || [];
  // Mirrors PlatformSettings.init(from:): rev. 1 data with a Friends list keeps "My list".
  const rules = settings.feedRules || (friends.length ? { feed: 'myList', stories: 'myList' } : {});
  const rulesOn = !!ff && setting(ff.toggle);
  const forced = new Set(rulesOn ? ff.forcedToggles || [] : []);
  const on = (t) => forced.has(t) || setting(t);
  // Mirrors ActiveRecipe.init(shortForm:).
  const keepRule = (x) => {
    if (!x.shortForm) return on(x.toggle);
    if (shortForm === 'budgetAllowed') return false;
    if (shortForm === 'forcedBlocked') return true;
    return on(x.toggle);
  };
  const keep = (list) => (list || []).filter(keepRule);
  let activeFriends;
  if (rulesOn) {
    // FeedRules.defaultAudience (beta, QUESTIONS #65): everyone I follow.
    const feed = allowed(rules.feed || 'everyone', friends, rules, people);
    const stories = allowed(rules.stories || 'everyone', friends, rules, people);
    const never = (rules.never || []).slice().sort();
    if (feed || stories || never.length) {
      const force = ff.forceFollowingToggle ? on(ff.forceFollowingToggle) : false;
      activeFriends = {
        feed, stories, never, forceFollowing: force, profileStories: rules.profileStories !== false,
        closePath: force && ff.followingQuery ? ff.feedPath + '?' + ff.followingQuery : ff.feedPath
      };
    }
  }
  const out = Object.assign({}, r, {
    routes: (settings.customBlocks || []).map((p, i) => ({
      id: 'custom.block.' + i, toggle: 'custom', pattern: p.startsWith('^') ? p : '^' + p, action: 'block'
    })).concat(keep(r.routes)),
    hide: keep(r.hide).concat((settings.customHides || []).map((s, i) => ({ id: 'custom.hide.' + i, toggle: 'custom', selector: s }))),
    heuristics: keep(r.heuristics),
    behaviors: (r.behaviors || []).filter((x) => on(x.toggle)),
    canaries: keep(r.canaries),
    resourceBlocks: keep(r.resourceBlocks)
  });
  // Mirrors ActiveRecipe's search modes (QUESTIONS #58): default normal.
  let searchMode;
  const sc = r.search;
  if (sc && on(sc.toggle)) {
    searchMode = settings.searchMode || 'normal';
    if (searchMode !== 'off') {
      const entry = new Set(sc.entryRules);
      out.routes = [{ id: 'ig.search.root', toggle: sc.toggle, pattern: sc.rootPattern, action: 'redirect', to: sc.searchPath }]
        .concat(out.routes.filter((x) => !entry.has(x.id)));
      out.hide = out.hide.filter((x) => !entry.has(x.id));
      out.heuristics = out.heuristics.filter((x) => !entry.has(x.id)).concat([{
        id: 'ig.search.grid', toggle: sc.toggle, type: 'anchorHref', pattern: sc.gridLink, hideAncestor: sc.gridAncestor, routes: sc.routes
      }]);
      out.canaries = out.canaries.filter((x) => !entry.has(x.id)).concat(sc.routes.map((route, i) => ({
        id: 'ig.search.gridCanary.' + i, toggle: sc.toggle, route, mustNotExist: { anchorHref: sc.gridLink }
      })));
    }
  }
  let landingKey = settings.landing && r.landing.options[settings.landing] ? settings.landing : r.landing.default;
  if (!signedIn && r.landing.signedOut && r.landing.options[r.landing.signedOut]) landingKey = r.landing.signedOut;
  const result = { recipe: out, landingPath: r.landing.options[landingKey], shortForm };
  if (activeFriends) result.friends = activeFriends;
  if (searchMode) result.searchMode = searchMode;
  return result;
}

// Mirrors PlatformSettings.allowed / base (Core/Friends.swift): (base(rule) ∪ always) − never,
// sorted; null = no audience filter.
function allowed(audience, myList, rules, people) {
  const p = people || {};
  const followers = p.followers || [], following = p.following || [], close = p.closeFriends || [];
  let base;
  if (audience === 'everyone') base = following.length ? following : null;
  else if (audience === 'mutuals') base = followers.length && following.length ? following.filter((u) => followers.includes(u)) : null;
  else if (audience === 'myList') base = myList;
  else base = close.length ? close : null;
  if (!base) return null;
  const never = new Set(rules.never || []);
  return [...new Set(base.concat(rules.always || []))].filter((u) => !never.has(u)).sort();
}

function dom(fixture, url) {
  const html = fs.readFileSync(path.join(__dirname, 'fixtures', fixture), 'utf8');
  return new JSDOM(html, { url, pretendToBeVisual: true });
}

module.exports = { bz, recipe, active, dom, allowed, KIT, SCRIPT };
