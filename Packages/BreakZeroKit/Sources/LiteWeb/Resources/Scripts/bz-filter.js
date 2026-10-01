/*
 * breakZero lite-view filter. Bundled with the app; never downloaded (App Store 2.5.2).
 * Recipes are data; this file is the only code that interprets them in the page.
 *
 * Layers (ARCHITECTURE.md §3): 2b route guard (history hooks), 3 CSS hide, 4 heuristics,
 * 5 canaries. Allow zones (DMs, login, compose…) get route rules only.
 *
 * Rules: subtractive only (hide / redirect / block). Match on URLs, hrefs, attributes and
 * structure — never on visible text. Every filter runs in its own try/catch so a broken
 * filter can never break the page or another filter.
 *
 * No browser globals at module top level: Node loads this file for tests (jstests/).
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = api;
  } else if (root) {
    root.__bzFilter = api;
  }
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  var ENGINE = 1;
  var HIDDEN_ATTR = 'data-bz-hidden';
  var BLUR_ATTR = 'data-bz-blur';

  // ---------------------------------------------------------------- pure helpers

  function re(pattern) {
    return new RegExp(pattern);
  }

  function compile(active) {
    var r = active.recipe;
    var scopes = {};
    Object.keys(r.scopes || {}).forEach(function (k) { scopes[k] = re(r.scopes[k]); });
    return {
      platform: r.platform,
      version: r.version,
      landingPath: active.landingPath,
      hosts: r.hosts || [],
      authHosts: r.authHosts || [],
      routes: (r.routes || []).map(function (x) { return { rule: x, re: re(x.pattern) }; }),
      scopes: scopes,
      allowZones: (r.allowZones || []).map(re),
      hide: (r.hide || []).map(function (h) {
        return { id: h.id, selector: h.selector, routes: h.routes ? h.routes.map(re) : null };
      }),
      heuristics: (r.heuristics || []).map(function (h) {
        return {
          id: h.id, type: h.type, pattern: h.pattern,
          re: h.type === 'anchorHref' ? re(h.pattern) : null,
          hideAncestor: h.hideAncestor || 0,
          routes: h.routes ? h.routes.map(re) : null
        };
      }),
      behaviors: (r.behaviors || []).map(function (b) {
        return {
          id: b.id, type: b.type, param: b.param || null, exemptParams: b.exemptParams || [],
          routes: b.routes ? b.routes.map(re) : null
        };
      }),
      canaries: (r.canaries || []).map(function (c) {
        return {
          id: c.id, route: re(c.route),
          anchorHref: c.mustNotExist.anchorHref ? re(c.mustNotExist.anchorHref) : null,
          selector: c.mustNotExist.selector || null
        };
      }),
      friends: compileFriends(r.friendsFilter, active.friends),
      scan: compileScan(r.friendsFilter)
    };
  }

  // ---------------------------------------------------------------- Old Instagram (§4c)

  var GATE_ID = 'ig.friends.storyGate';
  var FR_ATTR = 'data-bz-fr';
  var STORY_OK_ATTR = 'data-bz-story-ok';
  var CAUGHT_UP_ID = 'ig.caughtUp';

  function setOf(list) {
    var o = Object.create(null);
    (list || []).forEach(function (x) { o[String(x).toLowerCase()] = true; });
    return o;
  }

  /* Active only when native sent a Friends list (`active.friends`); see ActiveRecipe. */
  function compileFriends(ff, active) {
    if (!ff || !active || !active.usernames || !active.usernames.length) return null;
    return {
      set: setOf(active.usernames),
      forceFollowing: !!active.forceFollowing,
      feedRoutes: (ff.feedRoutes || []).map(re),
      feedPath: ff.feedPath || '/',
      followingQuery: ff.followingQuery || null,
      post: ff.post,
      profileLink: re(ff.profileLink),
      reserved: setOf(ff.reservedPaths),
      postLink: re(ff.postLink),
      storyTray: ff.storyTray,
      storyRoute: re(ff.storyRoute),
      storyExempt: setOf(ff.storyExempt),
      storyAuthor: ff.storyAuthor,
      caughtUpAfter: ff.caughtUpAfter || 20,
      idleMs: (ff.idleSeconds || 4) * 1000
    };
  }

  /* The setup collector works before any friend exists, so it doesn't depend on `active.friends`. */
  function compileScan(ff) {
    if (!ff || !ff.scanRoutes) return null;
    var routes = {};
    Object.keys(ff.scanRoutes).forEach(function (k) { routes[k] = re(ff.scanRoutes[k]); });
    return { routes: routes, profileLink: re(ff.profileLink), reserved: setOf(ff.reservedPaths), checked: ff.scanChecked };
  }

  function isFeed(f, path) {
    return f.feedRoutes.some(function (x) { return x.test(path); });
  }

  /* Username a profile path points at (lower-cased), or null for anything that isn't a profile. */
  function profileUser(f, path) {
    if (path == null) return null;
    var m = f.profileLink.exec(path);
    if (!m || !m.groups || !m.groups.user) return null;
    var u = m.groups.user.toLowerCase();
    return f.reserved[u] ? null : u;
  }

  /* The first profile link in an element (document order) — the post's author. Hrefs only. */
  function firstProfile(c, f, el, base) {
    var anchors = el.matches && el.matches('a[href]') ? [el] : el.querySelectorAll('a[href]');
    for (var i = 0; i < anchors.length; i++) {
      var u = profileUser(f, anchorPath(c, anchors[i], base));
      if (u) return u;
    }
    return null;
  }

  function hasQuery(search, query) {
    return ('&' + String(search || '').replace(/^\?/, '') + '&').indexOf('&' + query + '&') >= 0;
  }

  /* Feed URL to go to instead, when Following is forced and this feed URL isn't it. */
  function followingTarget(f, url) {
    if (!f || !f.forceFollowing || !f.followingQuery || !isFeed(f, url.pathname)) return null;
    if (hasQuery(url.search, f.followingQuery)) return null;
    var q = String(url.search || '').replace(/^\?/, '');
    return url.pathname + '?' + f.followingQuery + (q ? '&' + q : '');
  }

  /*
   * Feed pass: mark friend posts and tray items ok (default-deny CSS hides the rest), record the
   * tray order (for story skipping) and decide when the feed is "caught up". Re-checks every post
   * every time: React reuses nodes for new content. Returns { posts, okPosts, run, caughtUp }.
   */
  function runFriendsFeed(c, doc, path, base, fs, now) {
    var f = c.friends;
    var out = { posts: 0, okPosts: 0, run: 0, caughtUp: false };
    if (!f || !isFeed(f, path)) return out;
    var posts = doc.querySelectorAll(f.post);
    var lastOk = null;
    for (var i = 0; i < posts.length; i++) {
      var author = firstProfile(c, f, posts[i], base);
      if (author && f.set[author]) {
        if (posts[i].getAttribute(FR_ATTR) !== 'ok') posts[i].setAttribute(FR_ATTR, 'ok');
        lastOk = posts[i];
        out.okPosts++;
        out.run = 0;
      } else {
        if (posts[i].hasAttribute(FR_ATTR)) posts[i].removeAttribute(FR_ATTR);
        out.run++;
      }
    }
    out.posts = posts.length;

    var tray = doc.querySelectorAll(f.storyTray);
    var order = [];
    for (var j = 0; j < tray.length; j++) {
      var m = f.storyRoute.exec(anchorPath(c, tray[j], base) || '');
      var u = m && m.groups && m.groups.user ? m.groups.user.toLowerCase() : null;
      if (u && f.set[u]) {
        if (tray[j].getAttribute(FR_ATTR) !== 'ok') tray[j].setAttribute(FR_ATTR, 'ok');
      } else if (tray[j].hasAttribute(FR_ATTR)) {
        tray[j].removeAttribute(FR_ATTR);
      }
      if (u && order.indexOf(u) < 0) order.push(u);
    }
    if (order.length) fs.trayOrder = order;

    if (posts.length !== fs.postCount) { fs.postCount = posts.length; fs.lastNewPostAt = now; }
    var idle = posts.length > 0 && out.run > 0 && now - fs.lastNewPostAt >= f.idleMs;
    if (fs.card && fs.card.isConnected) {
      out.caughtUp = true;
    } else if (out.run >= f.caughtUpAfter || idle) {
      insertCaughtUp(doc, f, lastOk || posts[0], !lastOk, fs);
      out.caughtUp = !!fs.card;
    }
    return out;
  }

  /*
   * "You're all caught up": our card goes after the last friend post (or before the first post),
   * and everything after it inside <main> is hidden, so the rest of the list and the site's loader
   * stay out of view and loading stops. Our own element; the site's nodes are only hidden.
   */
  function insertCaughtUp(doc, f, anchorPost, before, fs) {
    if (!anchorPost) return;
    var row = anchorPost;
    // Climb to the post's row: the highest ancestor that holds no other post.
    while (row.parentElement && !STRUCTURAL.test(row.parentElement.tagName) &&
           row.parentElement.querySelectorAll(f.post).length <= 1) {
      row = row.parentElement;
    }
    var list = row.parentElement;
    if (!list) return;
    var card = doc.createElement('div');
    card.setAttribute('data-bz', 'caughtup');
    card.setAttribute('role', 'status');
    card.style.cssText = 'padding:28px 16px 40px;text-align:center;font:600 15px -apple-system,system-ui,sans-serif;opacity:.75';
    card.textContent = fs.caughtUpText || "You're all caught up";
    list.insertBefore(card, before ? row : row.nextSibling);
    // Hide what follows the list inside <main> too (the loader often sits outside the list).
    var el = list;
    while (el && el.parentElement && !STRUCTURAL.test(el.tagName)) {
      for (var sib = el.nextElementSibling; sib; sib = sib.nextElementSibling) {
        if (!sib.hasAttribute(HIDDEN_ATTR)) sib.setAttribute(HIDDEN_ATTR, CAUGHT_UP_ID);
      }
      el = el.parentElement;
    }
    fs.card = card;
  }

  function removeCaughtUp(doc, fs) {
    if (fs.card && fs.card.parentNode) fs.card.parentNode.removeChild(fs.card);
    fs.card = null;
    var marked = doc.querySelectorAll('[' + HIDDEN_ATTR + '="' + CAUGHT_UP_ID + '"]');
    for (var i = 0; i < marked.length; i++) marked[i].removeAttribute(HIDDEN_ATTR);
    fs.postCount = -1;
  }

  /*
   * Story viewer: ok only when the user in the URL is a friend (or exempt, e.g. highlights) and the
   * author shown in the viewer header, if any, is a friend. Marks <html data-bz-story-ok=path>;
   * CSS keeps the viewer hidden until then. Returns null when fine, else { user, author }.
   */
  function runFriendsStory(c, doc, path, base) {
    var f = c.friends;
    var root = doc.documentElement;
    var m = f ? f.storyRoute.exec(path) : null;
    if (!m) {
      if (root.hasAttribute(STORY_OK_ATTR)) root.removeAttribute(STORY_OK_ATTR);
      return null;
    }
    var user = m.groups && m.groups.user ? m.groups.user.toLowerCase() : '';
    var exempt = !!f.storyExempt[user];
    var author = null;
    var heads = doc.querySelectorAll(f.storyAuthor);
    for (var i = 0; i < heads.length && !author; i++) author = firstProfile(c, f, heads[i], base);
    var ok = (exempt || f.set[user]) && (author ? !!f.set[author] : !exempt);
    if (ok) {
      if (root.getAttribute(STORY_OK_ATTR) !== path) root.setAttribute(STORY_OK_ATTR, path);
      return null;
    }
    if (root.hasAttribute(STORY_OK_ATTR)) root.removeAttribute(STORY_OK_ATTR);
    // Exempt (highlights) with no author found yet: stay hidden, but it's not a violation yet.
    if (exempt && !author) return null;
    return { user: exempt ? author : user, author: author };
  }

  /* Next friend after `user` in the tray order we saw, skipping ones tried in this chain. */
  function nextFriendStory(f, order, user, tried) {
    var list = order || [];
    var i = list.indexOf(user);
    for (var k = i + 1; k < list.length; k++) {
      if (f.set[list[k]] && !(tried && tried[list[k]])) return '/stories/' + list[k] + '/';
    }
    return null;
  }

  /*
   * Setup collector: on the user's own Followers / Following / Close Friends page, read the
   * usernames of profile links already on screen. Read-only; never fetches. Close Friends: only
   * rows whose checkbox is checked. Returns { list, owner, usernames } of names not sent before.
   */
  function runScan(c, doc, path, base, sent) {
    var sc = c.scan;
    if (!sc) return null;
    var list = null, owner = null;
    Object.keys(sc.routes).forEach(function (k) {
      var m = !list && sc.routes[k].exec(path);
      if (m) { list = k; owner = m.groups && m.groups.owner ? m.groups.owner.toLowerCase() : null; }
    });
    if (!list) return null;
    var names = [];
    var seen = sent[list] || (sent[list] = Object.create(null));
    function take(u) {
      if (u && u !== owner && !seen[u]) { seen[u] = true; names.push(u); }
    }
    if (list === 'closeFriends') {
      var boxes = doc.querySelectorAll(sc.checked);
      var anyBox = doc.querySelectorAll('input[type=checkbox],[role=checkbox]').length > 0;
      if (!anyBox) return { list: list, owner: null, usernames: [], noCheckboxes: true };
      for (var i = 0; i < boxes.length; i++) {
        var row = boxes[i];
        var u = null;
        for (var up = 0; up < 8 && row && !u; up++) { u = firstProfile(c, sc, row, base); row = row.parentElement; }
        take(u);
      }
    } else {
      var anchors = doc.querySelectorAll('a[href]');
      for (var j = 0; j < anchors.length; j++) {
        if (anchors[j].closest('nav')) continue;
        take(profileUser(sc, anchorPath(c, anchors[j], base)));
      }
    }
    return { list: list, owner: owner, usernames: names.slice(0, 500) };
  }

  /*
   * Friends canaries: a post permalink visible outside any post container (the `post` selector no
   * longer matches, so default deny can't hide it), or a story link to a non-friend outside the tray
   * selector. Offenders are blurred. Returns failed canary ids.
   */
  function runFriendsCanaries(c, doc, path, base) {
    var f = c.friends;
    if (!f || !isFeed(f, path)) return [];
    var failed = [];
    var hideSelectors = activeHideSelectors(c, path);
    var anchors = doc.querySelectorAll('main a[href]');
    var total = doc.querySelectorAll('a[href]').length;
    var post = false, story = false;
    for (var i = 0; i < anchors.length; i++) {
      var a = anchors[i];
      if (isHiddenByUs(a, hideSelectors)) continue;
      var p = anchorPath(c, a, base);
      if (p === null) continue;
      if (f.postLink.test(p) && !a.closest(f.post)) {
        safeAncestor(a, 3, doc, total).setAttribute(BLUR_ATTR, 'ig.canary.friendsPost');
        post = true;
      }
      var m = f.storyRoute.exec(p);
      var u = m && m.groups && m.groups.user ? m.groups.user.toLowerCase() : null;
      if (u && !f.set[u] && !f.storyExempt[u] && !a.matches(f.storyTray)) {
        a.setAttribute(BLUR_ATTR, 'ig.canary.friendsStory');
        story = true;
      }
    }
    if (post) failed.push('ig.canary.friendsPost');
    if (story) failed.push('ig.canary.friendsStory');
    return failed;
  }

  function hostMatches(pattern, host) {
    host = String(host || '').toLowerCase();
    if (pattern.indexOf('*.') === 0) {
      var suffix = pattern.slice(1);
      return host.length > suffix.length && host.slice(-suffix.length) === suffix;
    }
    return host === pattern;
  }

  function isFilteredHost(c, host) {
    return c.hosts.some(function (p) { return hostMatches(p, host); });
  }

  function routesMatch(list, path) {
    if (!list) return true;
    return list.some(function (x) { return x.test(path); });
  }

  function isAllowZone(c, path) {
    return c.allowZones.some(function (z) { return z.test(path); });
  }

  // Same as RuleEngine.encodeComponent: ASCII alphanumerics and -._~@ stay raw.
  function encodeComponent(v) {
    return encodeURIComponent(v)
      .replace(/%40/g, '@')
      .replace(/[!'()*]/g, function (ch) { return '%' + ch.charCodeAt(0).toString(16).toUpperCase(); });
  }

  function fill(template, groups, landing) {
    var out = template.split('{landing}').join(landing);
    Object.keys(groups || {}).forEach(function (name) {
      if (groups[name] !== undefined) out = out.split('{' + name + '}').join(encodeComponent(groups[name]));
    });
    return out;
  }

  function stripQuery(s) {
    var i = s.indexOf('?');
    return i < 0 ? s : s.slice(0, i);
  }

  function redirectUnlessHere(target, here, reason, ruleID) {
    if (target === here) return { type: 'allow' };
    return { type: 'redirect', to: target, reason: reason, ruleID: ruleID };
  }

  /*
   * Mirror of RuleEngine.decide(path:query:previousPathAndQuery:state:) in Core.
   * `state` is { grant: {ruleID, key, returnTo} | null } and is mutated.
   * `query` excludes the leading '?', or is null.
   */
  function decide(c, path, query, previous, state) {
    path = path || '/';
    var here = query != null ? path + '?' + query : path;
    var previousPath = previous != null ? stripQuery(previous) : null;
    for (var i = 0; i < c.routes.length; i++) {
      var rule = c.routes[i].rule;
      var m = c.routes[i].re.exec(path);
      if (!m) continue;
      var groups = m.groups || {};
      switch (rule.action) {
        case 'allow':
          state.grant = null;
          return { type: 'allow' };
        case 'block':
          state.grant = null;
          return redirectUnlessHere(c.landingPath, here, 'blocked', rule.id);
        case 'redirect':
          state.grant = null;
          return redirectUnlessHere(fill(rule.to || '{landing}', groups, c.landingPath), here, 'redirected', rule.id);
        case 'allowOnce': {
          var key = rule.key && groups[rule.key] !== undefined ? groups[rule.key] : path;
          var g = state.grant;
          if (g && g.ruleID === rule.id) {
            if (g.key === key) return { type: 'allow' };
            state.grant = null;
            return redirectUnlessHere(g.returnTo, here, 'bounced', rule.id);
          }
          var scope = rule.scope ? c.scopes[rule.scope] : null;
          if (scope && previousPath != null && scope.test(previousPath)) {
            state.grant = { ruleID: rule.id, key: key, returnTo: previous };
            return { type: 'allow' };
          }
          state.grant = null;
          return redirectUnlessHere(c.landingPath, here, 'outOfScope', rule.id);
        }
      }
    }
    state.grant = null;
    return { type: 'allow' };
  }

  /* Full-URL wrapper used by tests and the guard: returns allow | redirect | external. */
  function decideURL(c, url, previousURL, state) {
    var u = new URL(url);
    var scheme = u.protocol.replace(':', '');
    if (scheme === 'about' || scheme === 'blob' || scheme === 'data') return { type: 'allow' };
    if (scheme !== 'https' && scheme !== 'http') return { type: 'external' };
    if (c.authHosts.some(function (p) { return hostMatches(p, u.hostname); })) return { type: 'allow' };
    if (!isFilteredHost(c, u.hostname)) return { type: 'external' };
    var prev = null;
    if (previousURL) {
      var p = new URL(previousURL);
      if (isFilteredHost(c, p.hostname)) prev = p.pathname + (p.search ? p.search : '');
    }
    return decide(c, u.pathname, u.search ? u.search.slice(1) : null, prev, state);
  }

  /* CSS for the current path: hide rules + our own attribute styles. Empty in allow zones. */
  function cssFor(c, path) {
    if (isAllowZone(c, path)) return '';
    var selectors = c.hide
      .filter(function (h) { return routesMatch(h.routes, path); })
      .map(function (h) { return h.selector; });
    var css = '[' + HIDDEN_ATTR + ']{display:none!important}' +
      '[' + BLUR_ATTR + ']{filter:blur(18px)!important;pointer-events:none!important;user-select:none!important}';
    // One rule per selector: an unsupported selector (e.g. :has on an old engine) only
    // drops its own rule, never the whole sheet.
    selectors.forEach(function (s) { css += s + '{display:none!important}'; });
    var f = c.friends;
    if (f && isFeed(f, path)) {
      // Default deny: a post or tray item shows only once the script marked it a friend's.
      css += ':is(' + f.post + '):not([' + FR_ATTR + '="ok"]){display:none!important}';
      css += ':is(' + f.storyTray + '):not([' + FR_ATTR + '="ok"]){display:none!important}';
      css += '[data-bz="caughtup"]~*{display:none!important}';
    }
    if (f && f.storyRoute.test(path)) {
      // The viewer stays invisible until this exact story was checked.
      css += 'html:not([' + STORY_OK_ATTR + ']) body{visibility:hidden!important}';
    }
    return css;
  }

  function activeHideSelectors(c, path) {
    return c.hide.filter(function (h) { return routesMatch(h.routes, path); }).map(function (h) { return h.selector; });
  }

  // ---------------------------------------------------------------- DOM glue

  /* Path of an <a>'s href when it points at a filtered host (or is relative). */
  function anchorPath(c, a, base) {
    var href = a.getAttribute('href');
    if (!href) return null;
    try {
      var u = new URL(href, base);
      if (!isFilteredHost(c, u.hostname)) return null;
      return u.pathname;
    } catch (e) {
      return null;
    }
  }

  var STRUCTURAL = /^(BODY|HTML|MAIN|NAV|HEADER|FOOTER|ASIDE|YTM-APP|YTD-APP|YTM-BROWSE|YTD-BROWSE)$/;
  var STRUCTURAL_ROLES = /^(main|navigation|feed|banner|contentinfo|tablist)$/;

  /*
   * Climb `levels` ancestors from a matched element, but never onto a container that could
   * hold allowed content: structural tags/roles, or anything holding more than half of the
   * page's links. A wrong `hideAncestor` in a recipe then hides too little, never the page.
   */
  function safeAncestor(el, levels, doc, totalAnchors) {
    var target = el;
    var limit = Math.max(2, Math.floor((totalAnchors || 0) / 2));
    for (var i = 0; i < levels; i++) {
      var p = target.parentElement;
      if (!p || STRUCTURAL.test(p.tagName) || STRUCTURAL_ROLES.test(p.getAttribute('role') || '')) break;
      if (p.querySelectorAll('a[href]').length > limit) break;
      target = p;
    }
    return target;
  }

  function isHiddenByUs(el, hideSelectors) {
    if (el.closest('[' + HIDDEN_ATTR + ']')) return true;
    for (var i = 0; i < hideSelectors.length; i++) {
      try {
        if (el.closest(hideSelectors[i])) return true;
      } catch (e) { /* selector unsupported here; treat as not hiding */ }
    }
    return false;
  }

  function runHeuristics(c, doc, path, base, report) {
    if (isAllowZone(c, path)) return 0;
    var hidden = 0;
    var anchors = null;
    c.heuristics.forEach(function (h) {
      if (!routesMatch(h.routes, path)) return;
      try {
        if (h.type === 'anchorHref') {
          anchors = anchors || doc.querySelectorAll('a[href]');
          for (var i = 0; i < anchors.length; i++) {
            var p = anchorPath(c, anchors[i], base);
            if (p !== null && h.re.test(p)) {
              var t = safeAncestor(anchors[i], h.hideAncestor, doc, anchors.length);
              if (!t.hasAttribute(HIDDEN_ATTR)) { t.setAttribute(HIDDEN_ATTR, h.id); hidden++; }
            }
          }
        } else if (h.type === 'selector') {
          var els = doc.querySelectorAll(h.pattern);
          for (var j = 0; j < els.length; j++) {
            var t2 = safeAncestor(els[j], h.hideAncestor, doc, doc.querySelectorAll('a[href]').length);
            if (!t2.hasAttribute(HIDDEN_ATTR)) { t2.setAttribute(HIDDEN_ATTR, h.id); hidden++; }
          }
        }
      } catch (e) {
        report({ type: 'filterError', id: h.id });
      }
    });
    return hidden;
  }

  function clearOurMarks(doc) {
    [HIDDEN_ATTR, BLUR_ATTR].forEach(function (attr) {
      var els = doc.querySelectorAll('[' + attr + ']');
      for (var i = 0; i < els.length; i++) els[i].removeAttribute(attr);
    });
  }

  /*
   * Canaries: assert forbidden things are absent. Returns ids of failed canaries.
   * Offending elements are blurred and made inert. A canary that throws counts as failed:
   * if we can't confirm the surface is gone, we cover it.
   */
  function runCanaries(c, doc, path, base, report) {
    if (isAllowZone(c, path)) return [];
    var failed = [];
    var hideSelectors = activeHideSelectors(c, path);
    c.canaries.forEach(function (k) {
      if (!k.route.test(path)) return;
      try {
        var offenders = [];
        if (k.anchorHref) {
          var anchors = doc.querySelectorAll('a[href]');
          for (var i = 0; i < anchors.length; i++) {
            var p = anchorPath(c, anchors[i], base);
            if (p !== null && k.anchorHref.test(p) && !isHiddenByUs(anchors[i], hideSelectors)) offenders.push(anchors[i]);
          }
        }
        if (k.selector) {
          var els = doc.querySelectorAll(k.selector);
          for (var j = 0; j < els.length; j++) {
            if (!isHiddenByUs(els[j], hideSelectors)) offenders.push(els[j]);
          }
        }
        if (offenders.length) {
          offenders.forEach(function (el) { el.setAttribute(BLUR_ATTR, k.id); });
          failed.push(k.id);
        }
      } catch (e) {
        failed.push(k.id);
        report({ type: 'filterError', id: k.id });
      }
    });
    return failed;
  }

  /* Diagnostics payload for a media event: never includes the media URL. */
  function mediaReport(event, el) {
    var src = String(el.currentSrc || el.src || '');
    return {
      type: 'media',
      event: event,
      kind: el.tagName === 'AUDIO' ? 'audio' : 'video',
      code: el.error && typeof el.error.code === 'number' ? el.error.code : null,
      source: src.indexOf('blob:') === 0 ? 'blob' : (src ? 'url' : 'none')
    };
  }

  function queryParam(search, name) {
    var m = new RegExp('[?&]' + name.replace(/[^A-Za-z0-9_]/g, '') + '=([^&#]*)').exec(search || '');
    return m ? m[1] : null;
  }

  /*
   * blockAutoAdvance: refuse an automatic move to a different item right after media ended
   * when the user didn't touch anything. Returns true to refuse.
   */
  function isAutoAdvance(c, from, to, ctx) {
    for (var i = 0; i < c.behaviors.length; i++) {
      var b = c.behaviors[i];
      if (b.type !== 'blockAutoAdvance') continue;
      if (!routesMatch(b.routes, from.pathname) || !routesMatch(b.routes, to.pathname)) continue;
      if (b.exemptParams.some(function (p) { return queryParam(from.search, p) !== null; })) continue;
      if (b.param && queryParam(from.search, b.param) === queryParam(to.search, b.param)) continue;
      var endedRecently = ctx.lastEndedAt > 0 && ctx.now - ctx.lastEndedAt < 15000;
      var noGestureSince = ctx.lastGestureAt < ctx.lastEndedAt;
      if (endedRecently && noGestureSince) return true;
    }
    return false;
  }

  /*
   * Watchdog (ARCHITECTURE.md §4b): is the page *as it is now* allowed? No side effects — the
   * state is copied, so a granted DM reel stays allowed and nothing is granted here.
   * Returns null when fine, else { reason, detail, ruleID, to } (`to` = where to go instead).
   * `limits.blocked` is set by native when a daily limit or schedule blocks the whole platform.
   */
  function watchdogCheck(c, href, state, limits) {
    if (limits && limits.blocked) {
      return { reason: 'limit', detail: String(limits.blocked), ruleID: null, to: c.landingPath };
    }
    var copy = { grant: state && state.grant ? state.grant : null };
    var d;
    try { d = decideURL(c, href, null, copy); } catch (e) { return null; }
    if (d.type === 'redirect') return { reason: d.reason, detail: null, ruleID: d.ruleID, to: d.to };
    return null;
  }

  function pauseAllMedia(doc) {
    var media = doc.querySelectorAll('video,audio');
    for (var i = 0; i < media.length; i++) {
      try { media[i].pause(); } catch (e) { /* keep going */ }
    }
  }

  /*
   * Install into a live page. `config` comes from native (LiteScriptBuilder):
   * { active: ActiveRecipe, state: {grant}, strings: {needsUpdate, report}, previousHref,
   *   limits: { blocked: reason | null } }
   * hooks (tests only): `replace(url)` / `assign(url)` instead of navigating (jsdom can't),
   * `setInterval(fn, ms)` instead of a real timer, `now()` instead of Date.now.
   */
  function install(win, config, hooks) {
    var doc = win.document;
    var replace = (hooks && hooks.replace) || function (u) { win.location.replace(u); };
    var assign = (hooks && hooks.assign) || function (u) { win.location.assign(u); };
    var clock = (hooks && hooks.now) || function () { return Date.now(); };
    var every = (hooks && hooks.setInterval) || function (fn, ms) { return win.setInterval(fn, ms); };
    var c = compile(config.active);
    var limits = config.limits || { blocked: null };
    var lastViolationAt = 0;
    var state = config.state || { grant: null };
    var strings = config.strings || {};
    var lastHref = win.location.href;
    var ctx = { lastEndedAt: 0, lastGestureAt: 0, now: 0 };
    var scheduled = false;
    var overlay = null;
    // Old Instagram: per-page state. The tray order survives the full loads a story skip does.
    var scanOn = !!config.scan;
    var fs = { postCount: -1, lastNewPostAt: 0, trayOrder: session('bz.tray') || [], card: null, cardHref: null,
               caughtUpText: strings.caughtUp, scanSent: {}, scanNoChecked: false, gaveUp: false };

    function session(key, value) {
      try {
        if (arguments.length > 1) { win.sessionStorage.setItem(key, JSON.stringify(value)); return value; }
        return JSON.parse(win.sessionStorage.getItem(key) || 'null');
      } catch (e) { return null; }
    }

    function post(msg) {
      try {
        var h = win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.bz;
        if (h) h.postMessage(msg);
      } catch (e) { /* native side gone; nothing to do */ }
    }

    var styleEl = doc.createElement('style');
    styleEl.setAttribute('data-bz', 'style');
    (doc.head || doc.documentElement).appendChild(styleEl);

    function refresh() {
      var path = win.location.pathname;
      try {
        styleEl.textContent = cssFor(c, path);
        if (!styleEl.isConnected) (doc.head || doc.documentElement).appendChild(styleEl);
      } catch (e) { post({ type: 'filterError', id: 'css' }); }
      if (isAllowZone(c, path)) {
        clearOurMarks(doc);
        removeOverlay();
      }
      var here = path + win.location.search;
      if (fs.cardHref !== null && fs.cardHref !== here) { removeCaughtUp(doc, fs); fs.cardHref = null; }
      checkStory();
      schedule();
    }

    /* Story viewer: synchronous, so a non-friend story is caught before the next frame. */
    function checkStory() {
      try {
        var v = runFriendsStory(c, doc, win.location.pathname, win.location.href);
        if (v) violate({ reason: 'redirected', detail: null, ruleID: GATE_ID, to: storyTarget(v.user) });
      } catch (e) { post({ type: 'filterError', id: 'friends.story' }); }
    }

    /* Where a gated story goes: the next friend in the tray we saw, else back to the feed. */
    function storyTarget(user) {
      var f = c.friends;
      if (!f) return c.landingPath;
      var next = nextFriendStory(f, fs.trayOrder, user);
      post({ type: 'friends', event: next ? 'storySkipped' : 'storyClosed' });
      if (next) return next;
      return f.feedPath + (f.forceFollowing && f.followingQuery ? '?' + f.followingQuery : '');
    }

    function storyUser(href) {
      try {
        var m = c.friends && c.friends.storyRoute.exec(new URL(href, win.location.href).pathname);
        return m && m.groups && m.groups.user ? m.groups.user.toLowerCase() : null;
      } catch (e) { return null; }
    }

    /* Force the Following feed, at most 3 times per 30 s; then give up (the filter still holds). */
    function allowFollowingRedirect() {
      var now = clock();
      var recent = (session('bz.ff') || []).filter(function (t) { return now - t < 30000; });
      if (recent.length >= 3) {
        if (!fs.gaveUp) { fs.gaveUp = true; post({ type: 'friends', event: 'followingGaveUp' }); }
        return false;
      }
      recent.push(now);
      session('bz.ff', recent);
      return true;
    }

    function maybeForceFollowing(navigate) {
      var target;
      try { target = followingTarget(c.friends, win.location); } catch (e) { target = null; }
      if (!target || !allowFollowingRedirect()) return false;
      post({ type: 'friends', event: 'forcedFollowing' });
      (navigate || replace)(target);
      return true;
    }

    function tick() {
      scheduled = false;
      var path = win.location.pathname;
      var href = win.location.href;
      // Backstop: a URL change we didn't see (e.g. a router holding an old reference).
      if (href !== lastHref) onURLChanged(lastHref);
      runHeuristics(c, doc, path, href, post);
      try {
        runFriendsFeed(c, doc, path, href, fs, clock());
        if (fs.card && fs.cardHref === null) {
          fs.cardHref = path + win.location.search;
          post({ type: 'friends', event: 'caughtUp' });
        }
      } catch (e) { post({ type: 'filterError', id: 'friends.feed' }); }
      checkStory();
      if (scanOn) {
        try {
          var r = runScan(c, doc, path, href, fs.scanSent);
          if (r && r.noCheckboxes) {
            if (!fs.scanNoChecked) { fs.scanNoChecked = true; post({ type: 'friends', event: 'scanNoChecked' }); }
          } else if (r && r.usernames.length) {
            post({ type: 'friendsScan', list: r.list, owner: r.owner, usernames: r.usernames });
          }
        } catch (e) { post({ type: 'filterError', id: 'friends.scan' }); }
      }
      if (fs.trayOrder.length) session('bz.tray', fs.trayOrder);
      var failed = runCanaries(c, doc, path, href, post);
      try { failed = failed.concat(runFriendsCanaries(c, doc, path, href)); } catch (e) {
        failed.push('ig.canary.friends');
        post({ type: 'filterError', id: 'friends.canary' });
      }
      if (failed.length) showOverlay(failed); else removeOverlay();
    }

    function schedule() {
      if (scheduled) return;
      scheduled = true;
      (win.requestAnimationFrame || function (f) { return win.setTimeout(f, 16); })(tick);
    }

    function showOverlay(ids) {
      if (overlay && overlay.isConnected) return;
      overlay = doc.createElement('div');
      overlay.setAttribute('data-bz', 'overlay');
      overlay.setAttribute('role', 'alert');
      overlay.style.cssText = 'position:fixed;left:12px;right:12px;bottom:calc(env(safe-area-inset-bottom) + 72px);' +
        'z-index:2147483647;background:rgba(20,20,20,.94);color:#fff;border-radius:14px;padding:12px 14px;' +
        'font:15px -apple-system,system-ui,sans-serif;display:flex;gap:10px;align-items:center';
      var text = doc.createElement('span');
      text.style.flex = '1';
      text.textContent = strings.needsUpdate || 'Filter needs an update';
      var btn = doc.createElement('button');
      btn.type = 'button';
      btn.textContent = strings.report || 'Report';
      btn.style.cssText = 'background:#fff;color:#000;border:0;border-radius:10px;padding:6px 12px;font:inherit';
      btn.addEventListener('click', function () { post({ type: 'report', ids: ids }); });
      overlay.appendChild(text);
      overlay.appendChild(btn);
      doc.documentElement.appendChild(overlay);
      post({ type: 'canary', ids: ids, path: win.location.pathname });
    }

    function removeOverlay() {
      if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
      overlay = null;
    }

    function check(targetHref, fromHref) {
      var d = decideURL(c, targetHref, fromHref, state);
      if (d.type === 'redirect' && d.ruleID === GATE_ID) d.to = storyTarget(storyUser(targetHref));
      if (d.type === 'allow' && fromHref) {
        ctx.now = Date.now();
        if (isAutoAdvance(c, new URL(fromHref), new URL(targetHref), ctx)) {
          return { type: 'refuse', reason: 'autoAdvance' };
        }
      }
      return d;
    }

    function enforce(d, fromHref) {
      if (d.type === 'redirect') {
        post({ type: 'redirect', reason: d.reason, ruleID: d.ruleID, state: state });
        replace(d.to);
        return false;
      }
      if (d.type === 'refuse') {
        post({ type: 'refuse', reason: d.reason });
        replace(fromHref);
        return false;
      }
      return true;
    }

    function onURLChanged(fromHref) {
      var d = check(win.location.href, fromHref);
      lastHref = win.location.href;
      if (enforce(d, fromHref)) {
        if (maybeForceFollowing()) return;
        post({ type: 'route', href: win.location.href, state: state });
        refresh();
      }
    }

    // Layer 2b: SPA navigation. Patch the prototype too, so routers holding a reference to
    // History.prototype.pushState are covered.
    ['pushState', 'replaceState'].forEach(function (name) {
      var proto = win.History && win.History.prototype;
      var original = (proto && proto[name]) || win.history[name];
      var wrapped = function (s, t, url) {
        if (url !== undefined && url !== null) {
          var target;
          try { target = new URL(String(url), win.location.href).href; } catch (e) { target = null; }
          if (target && target !== win.location.href) {
            var d = check(target, win.location.href);
            if (d.type === 'external') return original.apply(this, arguments);
            if (!enforce(d, win.location.href)) return undefined;
            // Logo/Home tap or the site's own feed link: go to the Following feed instead. A
            // replaceState that only drops the variant from the URL we're already on is the site
            // tidying its URL; the content is already the Following feed, so let it be.
            var ft = null;
            try { ft = followingTarget(c.friends, new URL(target)); } catch (e) { ft = null; }
            var tidy = name === 'replaceState' && c.friends && c.friends.followingQuery &&
              hasQuery(win.location.search, c.friends.followingQuery) &&
              new URL(target).pathname === win.location.pathname;
            if (ft && !tidy && allowFollowingRedirect()) {
              post({ type: 'friends', event: 'forcedFollowing' });
              (name === 'pushState' ? assign : replace)(ft);
              return undefined;
            }
          }
        }
        var result = original.apply(this, arguments);
        if (win.location.href !== lastHref) {
          lastHref = win.location.href;
          post({ type: 'route', href: lastHref, state: state });
          refresh();
        }
        return result;
      };
      try {
        if (proto) proto[name] = wrapped;
        win.history[name] = wrapped;
      } catch (e) { post({ type: 'filterError', id: 'history.' + name }); }
    });

    win.addEventListener('popstate', function () {
      if (win.location.href !== lastHref) onURLChanged(lastHref);
    });

    // Gestures and media end, for blockAutoAdvance. Capture phase: `ended` doesn't bubble.
    ['pointerdown', 'touchstart', 'keydown', 'click'].forEach(function (t) {
      doc.addEventListener(t, function () { ctx.lastGestureAt = Date.now(); }, true);
    });
    doc.addEventListener('ended', function () { ctx.lastEndedAt = Date.now(); }, true);

    // Playback diagnostics (passive listeners only; the player itself is never touched): report
    // media errors, the first stall and the first successful start per element, so Diagnostics
    // can say *why* a video didn't play. No URLs leave the page: only "blob"/"url"/"none".
    var mediaSeen = { playing: new WeakSet(), stalled: new WeakSet() };
    ['error', 'stalled', 'playing'].forEach(function (t) {
      doc.addEventListener(t, function (ev) {
        var el = ev.target;
        if (!el || (el.tagName !== 'VIDEO' && el.tagName !== 'AUDIO')) return;
        if (mediaSeen[t]) {
          if (mediaSeen[t].has(el)) return;
          mediaSeen[t].add(el);
        }
        post(mediaReport(t, el));
      }, true);
    });

    // Layer 4 trigger: throttled with requestAnimationFrame.
    try {
      var mo = new win.MutationObserver(schedule);
      mo.observe(doc.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['href'] });
    } catch (e) { post({ type: 'filterError', id: 'observer' }); }

    /*
     * Watchdog: every ~1 s and on every navigation event, re-check the page as it is. Catches
     * anything that got past the guard (an unhooked router, a swipe, a budget that ran out
     * mid-video). On a violation: stop loading, pause media, go to the safe page, tell native
     * (toast + log). Debounced 2 s so the landing page can load.
     */
    function violate(v) {
      var here = win.location.pathname + win.location.search;
      // Platform blocked and already on its landing page: keep media paused, don't repeat.
      if (v.reason === 'limit' && v.to === here) { pauseAllMedia(doc); return; }
      var now = Date.now();
      if (now - lastViolationAt < 2000) return;
      lastViolationAt = now;
      try { win.stop(); } catch (e) { /* not supported */ }
      pauseAllMedia(doc);
      post({ type: 'violation', reason: v.reason, detail: v.detail, ruleID: v.ruleID });
      if (v.to && v.to !== here) replace(v.to);
    }

    function watchdog() {
      try {
        if (win.location.href !== lastHref) {
          // A URL change the guard never saw: decide it as a navigation (so a DM reel can still
          // be granted), and if it's not allowed, treat it as a violation — the page is showing.
          var from = lastHref;
          var d = check(win.location.href, from);
          lastHref = win.location.href;
          if (d.type === 'redirect') {
            violate({ reason: d.reason, detail: null, ruleID: d.ruleID, to: d.to });
            return;
          }
          if (d.type === 'refuse') {
            var f = new URL(from);
            violate({ reason: 'autoAdvance', detail: null, ruleID: null, to: f.pathname + f.search });
            return;
          }
          if (maybeForceFollowing()) return;
          post({ type: 'route', href: win.location.href, state: state });
          refresh();
        }
        var v = watchdogCheck(c, win.location.href, state, limits);
        if (v && v.ruleID === GATE_ID) v.to = storyTarget(storyUser(win.location.href));
        if (v) violate(v);
        schedule();
      } catch (e) {
        post({ type: 'filterError', id: 'watchdog' });
      }
    }

    every(watchdog, 1000);
    ['hashchange', 'pageshow', 'focus'].forEach(function (t) { win.addEventListener(t, watchdog); });
    doc.addEventListener('visibilitychange', function () { if (!doc.hidden) watchdog(); });

    // Native pushes new rules/limits here (budget ran out, schedule started) without a reload.
    // Page scripts could call it too; the native watchdog checks independently every second.
    win.__bzUpdate = function (next) {
      try {
        if (next && next.active) c = compile(next.active);
        if (next && next.limits) limits = next.limits;
        if (next && typeof next.scan === 'boolean') { scanOn = next.scan; fs.scanSent = {}; fs.scanNoChecked = false; }
        refresh();
        watchdog();
      } catch (e) {
        post({ type: 'filterError', id: 'update' });
      }
    };

    // The first document load: native already ran the same decision; this is the backstop.
    var first = check(win.location.href, config.previousHref || null);
    if (first.type === 'redirect') enforce(first, win.location.href);
    else maybeForceFollowing();
    refresh();
    if (limits.blocked) watchdog();

    return {
      state: state,
      get compiled() { return c; },
      get limits() { return limits; },
      tick: tick,
      refresh: refresh,
      watchdog: watchdog,
      ctx: ctx,
      friendsState: fs
    };
  }

  return {
    ENGINE: ENGINE,
    compile: compile,
    decide: decide,
    decideURL: decideURL,
    encodeComponent: encodeComponent,
    isAllowZone: isAllowZone,
    cssFor: cssFor,
    runHeuristics: runHeuristics,
    runCanaries: runCanaries,
    isAutoAdvance: isAutoAdvance,
    mediaReport: mediaReport,
    watchdogCheck: watchdogCheck,
    GATE_ID: GATE_ID,
    profileUser: profileUser,
    followingTarget: followingTarget,
    runFriendsFeed: runFriendsFeed,
    runFriendsStory: runFriendsStory,
    nextFriendStory: nextFriendStory,
    runScan: runScan,
    runFriendsCanaries: runFriendsCanaries,
    removeCaughtUp: removeCaughtUp,
    install: install
  };
});
