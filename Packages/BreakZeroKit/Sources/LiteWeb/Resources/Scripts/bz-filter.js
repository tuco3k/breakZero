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
      scan: compileScan(r.friendsFilter),
      // Search "Only accounts that match my feed rules" (QUESTIONS #60): the search pages to filter.
      searchMatching: active.searchMode === 'matching' && r.search ? (r.search.routes || []).map(re) : null
    };
  }

  // ---------------------------------------------------------------- Feed rules (§4c rev. 2)

  var GATE_ID = 'ig.friends.storyGate';
  var FR_ATTR = 'data-bz-fr';
  var STORY_OK_ATTR = 'data-bz-story-ok';
  var CAUGHT_UP_ID = 'ig.caughtUp';

  function setOf(list) {
    var o = Object.create(null);
    (list || []).forEach(function (x) { o[String(x).toLowerCase()] = true; });
    return o;
  }

  /*
   * Active only when native sent feed rules that filter something (`active.friends`, see
   * ActiveRecipe): per-surface allowed sets (null = everyone) and the never-show set.
   */
  function compileFriends(ff, active) {
    if (!ff || !active) return null;
    return {
      feed: active.feed ? setOf(active.feed) : null,
      stories: active.stories ? setOf(active.stories) : null,
      never: setOf(active.never),
      forceFollowing: !!active.forceFollowing,
      profileStories: active.profileStories !== false,
      closePath: active.closePath || ff.feedPath || '/',
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
      findingAfter: ff.findingAfter || 5,
      idleMs: (ff.idleSeconds || 4) * 1000
    };
  }

  /* Mirrors ActiveFriends.allows: never beats everything; null set = everyone. */
  function allows(f, surface, u) {
    if (!u || f.never[u]) return false;
    var set = surface === 'feed' ? f.feed : f.stories;
    return set === null || !!set[u];
  }

  /* The setup collectors work before any rule exists, so they don't depend on `active.friends`. */
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

  function storyUserOf(f, path) {
    var m = f.storyRoute.exec(path || '');
    return m && m.groups && m.groups.user ? m.groups.user.toLowerCase() : null;
  }

  function trimSlash(p) {
    return p.length > 1 && p.charAt(p.length - 1) === '/' ? p.slice(0, -1) : p;
  }

  /*
   * Story gate: mirror of StoryGate.decide in RuleEngine.swift (shared route vectors).
   * `state.storyUser` = the person whose stories were opened from their profile on purpose.
   */
  function storyDecision(f, user, here, previousPath, previous, state) {
    if (f.storyExempt[user]) return { type: 'allow' };
    if (state.storyUser) {
      if (state.storyUser === user) return { type: 'allow' };
      var opened = state.storyUser;
      state.storyUser = null;
      return redirectUnlessHere('/' + opened + '/', here, 'bounced', GATE_ID);
    }
    if (allows(f, 'stories', user)) return { type: 'allow' };
    var fromProfile = previousPath != null && trimSlash(previousPath).toLowerCase() === '/' + user;
    if (fromProfile) {
      if (f.profileStories && !f.never[user]) { state.storyUser = user; return { type: 'allow' }; }
      return redirectUnlessHere('/' + user + '/', here, 'bounced', GATE_ID);
    }
    if (previousPath != null && previous != null && storyUserOf(f, previousPath) === null && !isFeed(f, previousPath)) {
      return redirectUnlessHere(previous, here, 'bounced', GATE_ID);
    }
    return redirectUnlessHere(f.closePath, here, 'redirected', GATE_ID);
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
   * Feed screening (QUESTIONS #61). Every feed item is hidden by CSS until it carries
   * data-bz-fr="ok". Items are found by the recipe's selector *and* structurally (the block around a
   * single post permalink, whatever its tag, marked data-bz-post), and screened synchronously in the
   * MutationObserver callback, before the browser paints. A reused node whose content changed is
   * re-screened the same way. Rejected items carry data-bz-fr="no" and take no space.
   */
  var POST_ATTR = 'data-bz-post';

  function permalinkPath(c, f, a, base) {
    var p = anchorPath(c, a, base);
    return p !== null && f.postLink.test(p) ? p : null;
  }

  /* Distinct post permalinks inside an element (a post links to itself more than once). */
  function permalinkCount(c, f, el, base, limit) {
    var seen = Object.create(null), n = 0;
    var anchors = el.querySelectorAll('a[href]');
    for (var i = 0; i < anchors.length && n <= limit; i++) {
      var p = permalinkPath(c, f, anchors[i], base);
      if (p !== null && !seen[p]) { seen[p] = true; n++; }
    }
    return n;
  }

  /*
   * Structural fallback: for a permalink not inside a recognized post, the post is the highest
   * ancestor that still holds only this one post (below <main>, never the stories tray or our own
   * elements). Marked data-bz-post so the CSS default-deny covers it too.
   */
  function discoverPosts(c, f, root, base) {
    var found = [];
    var anchors = root.matches && root.matches('a[href]') ? [root] : root.querySelectorAll('a[href]');
    for (var i = 0; i < anchors.length; i++) {
      var a = anchors[i];
      if (!a.closest('main') || a.closest(f.post) || a.closest('[' + POST_ATTR + ']') || a.closest('[data-bz]')) continue;
      if (permalinkPath(c, f, a, base) === null) continue;
      var el = a;
      while (el.parentElement && !STRUCTURAL.test(el.parentElement.tagName) && !el.parentElement.closest('[data-bz]') &&
             !el.parentElement.querySelector(f.storyTray) && permalinkCount(c, f, el.parentElement, base, 1) <= 1) {
        el = el.parentElement;
      }
      if (el !== a && !el.hasAttribute(POST_ATTR)) { el.setAttribute(POST_ATTR, ''); found.push(el); }
    }
    return found;
  }

  function postSelector(f) {
    return f.post + ',[' + POST_ATTR + ']';
  }

  /* Decide one post. Returns 'ok' | 'no'. */
  function decidePost(c, f, post, base) {
    var author = firstProfile(c, f, post, base);
    return allows(f, 'feed', author) ? 'ok' : 'no';
  }

  function decideTrayItem(c, f, item, base) {
    var u = storyUserOf(f, anchorPath(c, item, base) || '');
    return u && (allows(f, 'stories', u) || f.storyExempt[u]) ? 'ok' : 'no';
  }

  /*
   * Screen everything at or under `roots` (and the posts that contain them). Synchronous. Keeps the
   * scroll position when an approved item above the viewport goes away. Returns { posts, changed }.
   */
  function screenRoots(c, doc, path, base, roots, win) {
    var f = c.friends;
    var out = { posts: 0, changed: 0 };
    if (!f || !isFeed(f, path)) return out;
    var sel = postSelector(f);
    var posts = [], trays = [];
    function addPost(p) { if (posts.indexOf(p) < 0) posts.push(p); }
    function addTray(t) { if (trays.indexOf(t) < 0) trays.push(t); }
    for (var i = 0; i < roots.length; i++) {
      var r = roots[i];
      if (!r || r.nodeType !== 1 || (r.closest && r.closest('[data-bz]') && !r.closest(sel))) continue;
      discoverPosts(c, f, r, base);
      var up = r.closest(sel);
      if (up) addPost(up);
      var inner = r.querySelectorAll(sel);
      for (var j = 0; j < inner.length; j++) addPost(inner[j]);
      var tUp = r.closest(f.storyTray);
      if (tUp) addTray(tUp);
      var tIn = r.querySelectorAll(f.storyTray);
      for (var k = 0; k < tIn.length; k++) addTray(tIn[k]);
    }
    // Decide first, then apply, so the scroll anchor is measured before anything moves.
    var decisions = posts.map(function (p) { return decidePost(c, f, p, base); });
    var anchor = null, anchorTop = 0;
    var losing = posts.some(function (p, n) { return decisions[n] === 'no' && p.getAttribute(FR_ATTR) === 'ok' && isAbove(p); });
    if (losing && win) {
      var shown = doc.querySelectorAll('[' + FR_ATTR + '="ok"]');
      for (var s = 0; s < shown.length && !anchor; s++) {
        var idx = posts.indexOf(shown[s]);
        if (idx >= 0 && decisions[idx] === 'no') continue;
        var rect = shown[s].getBoundingClientRect();
        if (rect.bottom > 0) { anchor = shown[s]; anchorTop = rect.top; }
      }
    }
    posts.forEach(function (p, n) {
      if (p.getAttribute(FR_ATTR) !== decisions[n]) { p.setAttribute(FR_ATTR, decisions[n]); out.changed++; }
    });
    trays.forEach(function (t) {
      var d = decideTrayItem(c, f, t, base);
      if (t.getAttribute(FR_ATTR) !== d) { t.setAttribute(FR_ATTR, d); out.changed++; }
    });
    if (anchor) {
      var delta = anchor.getBoundingClientRect().top - anchorTop;
      if (delta) { try { win.scrollBy(0, delta); } catch (e) { /* not scrollable */ } }
    }
    out.posts = posts.length;
    return out;
  }

  function isAbove(el) {
    try { return el.getBoundingClientRect().bottom <= 0; } catch (e) { return false; }
  }

  /*
   * Feed pass (frame tick): full screen, then the slower parts: hide buttons, the tray order (for
   * story skipping), who was hidden (status pill), "Finding posts…" and "You're all caught up".
   * Returns { posts, okPosts, run, caughtUp, finding, hidden: [usernames] }.
   */
  function runFriendsFeed(c, doc, path, base, fs, now, win) {
    var f = c.friends;
    var out = { posts: 0, okPosts: 0, run: 0, caughtUp: false, finding: false, hidden: [] };
    if (!f || !isFeed(f, path)) return out;
    screenRoots(c, doc, path, base, [doc.documentElement], win);
    var seen = fs.hiddenSeen || (fs.hiddenSeen = Object.create(null));
    function hid(u) {
      if (u && !seen[u]) { seen[u] = true; out.hidden.push(u); }
    }
    var posts = doc.querySelectorAll(postSelector(f));
    var lastOk = null;
    for (var i = 0; i < posts.length; i++) {
      var author = firstProfile(c, f, posts[i], base);
      if (posts[i].getAttribute(FR_ATTR) === 'ok') {
        posts[i].setAttribute('data-bz-author', author);
        ensureHideButton(doc, posts[i], author, fs);
        lastOk = posts[i];
        out.okPosts++;
        out.run = 0;
      } else {
        hid(author);
        out.run++;
      }
    }
    out.posts = posts.length;

    var tray = doc.querySelectorAll(f.storyTray);
    var order = [];
    for (var j = 0; j < tray.length; j++) {
      var u = storyUserOf(f, anchorPath(c, tray[j], base) || '');
      if (tray[j].getAttribute(FR_ATTR) !== 'ok') hid(u);
      if (u && order.indexOf(u) < 0) order.push(u);
    }
    if (order.length) fs.trayOrder = order;

    if (posts.length !== fs.postCount) { fs.postCount = posts.length; fs.lastNewPostAt = now; }
    var idle = posts.length > 0 && out.run > 0 && now - fs.lastNewPostAt >= f.idleMs;
    if (fs.card && fs.card.isConnected) {
      out.caughtUp = true;
    } else if (out.run >= f.caughtUpAfter || idle) {
      removeFinding(fs);
      insertCaughtUp(doc, f, lastOk || posts[0], !lastOk, fs);
      out.caughtUp = !!fs.card;
    }
    if (!out.caughtUp && out.run >= f.findingAfter && posts.length) {
      placeFinding(doc, f, lastOk || posts[0], !lastOk, fs);
      out.finding = true;
    } else if (!out.caughtUp) {
      removeFinding(fs);
    }
    return out;
  }

  /* The post's row: the highest ancestor that holds no other post. */
  function rowOf(f, post) {
    var row = post;
    var sel = postSelector(f);
    while (row.parentElement && !STRUCTURAL.test(row.parentElement.tagName) &&
           row.parentElement.querySelectorAll(sel).length <= 1) {
      row = row.parentElement;
    }
    return row;
  }

  /* "Finding posts from your people…": after the last shown post while many are hidden in a row. */
  function placeFinding(doc, f, anchorPost, before, fs) {
    if (!anchorPost) return;
    var row = rowOf(f, anchorPost);
    var list = row.parentElement;
    if (!list) return;
    var card = fs.finding && fs.finding.isConnected ? fs.finding : null;
    var where = before ? row : row.nextSibling;
    if (card && (before ? card.nextSibling === row : card.previousSibling === row)) return;
    if (!card) {
      card = doc.createElement('div');
      card.setAttribute('data-bz', 'finding');
      card.setAttribute('role', 'status');
      card.style.cssText = 'padding:22px 16px;text-align:center;font:500 14px -apple-system,system-ui,sans-serif;opacity:.6';
      card.textContent = fs.findingText || 'Finding posts from your people…';
      fs.finding = card;
    }
    list.insertBefore(card, where);
  }

  function removeFinding(fs) {
    if (fs.finding && fs.finding.parentNode) fs.finding.parentNode.removeChild(fs.finding);
    fs.finding = null;
  }

  /* Diagnostics: what the feed is made of on this page (counts and tag shapes, never names). */
  function feedReport(c, doc, path, base) {
    var f = c.friends;
    var r = { feed: !!(f && isFeed(f, path)), rulesActive: !!f, main: !!doc.querySelector('main') };
    r.article = doc.querySelectorAll('article').length;
    r.mainArticle = doc.querySelectorAll('main article').length;
    r.roleArticle = doc.querySelectorAll('[role="article"]').length;
    if (!f) return r;
    r.recipeSelector = f.post;
    r.matchedBySelector = doc.querySelectorAll(f.post).length;
    r.discovered = doc.querySelectorAll('[' + POST_ATTR + ']').length;
    r.approved = doc.querySelectorAll('[' + FR_ATTR + '="ok"]').length;
    r.rejected = doc.querySelectorAll('[' + FR_ATTR + '="no"]').length;
    var anchors = doc.querySelectorAll('main a[href]');
    var perma = 0, outside = 0, first = null;
    for (var i = 0; i < anchors.length; i++) {
      if (permalinkPath(c, f, anchors[i], base) === null) continue;
      perma++;
      if (!anchors[i].closest(postSelector(f))) outside++;
      if (!first) first = anchors[i];
    }
    r.permalinks = perma;
    r.permalinksOutsidePosts = outside;
    r.trayItems = doc.querySelectorAll(f.storyTray).length;
    if (first) {
      var chain = [];
      for (var el = first.parentElement; el && chain.length < 10 && el.tagName !== 'BODY'; el = el.parentElement) {
        var role = el.getAttribute('role');
        chain.push(el.tagName.toLowerCase() + (role ? '[role=' + role + ']' : '') + (el.hasAttribute(POST_ATTR) ? '{post}' : '') +
          (el.matches(f.post) ? '{selector}' : ''));
      }
      r.firstPostShape = chain.reverse().join(' > ');
    }
    return r;
  }

  /* Diagnostics: is any unapproved post painted? A post is painted if any of its links has boxes. */
  function paintedUnapproved(c, doc, path, base) {
    var f = c.friends;
    if (!f || !isFeed(f, path)) return 0;
    var anchors = doc.querySelectorAll('main a[href]');
    var bad = 0;
    for (var i = 0; i < anchors.length; i++) {
      if (permalinkPath(c, f, anchors[i], base) === null) continue;
      var post = anchors[i].closest(postSelector(f));
      var ok = post && post.getAttribute(FR_ATTR) === 'ok';
      if (!ok && anchors[i].getClientRects().length > 0) bad++;
    }
    return bad;
  }

  /*
   * One-tap "hide this account": our own small button over the corner of a shown post (an
   * addition; nothing of the site's changes). Tapping it posts `hideAccount` to native (narrowing,
   * instant) and hides the post here at once.
   */
  function ensureHideButton(doc, post, author, fs) {
    var wrap = post.querySelector(':scope > [data-bz="hidewrap"]');
    var btn = wrap && wrap.querySelector('button');
    if (btn && btn.getAttribute('data-bz-user') === author) return;
    if (wrap) wrap.parentNode.removeChild(wrap);
    // Our own zero-height, positioned wrapper as the post's first child: the button sits over the
    // post's top corner without changing any of the site's elements (not even their position).
    wrap = doc.createElement('div');
    wrap.setAttribute('data-bz', 'hidewrap');
    wrap.style.cssText = 'position:relative;height:0;overflow:visible;z-index:5';
    btn = doc.createElement('button');
    btn.type = 'button';
    btn.setAttribute('data-bz-user', author);
    btn.setAttribute('aria-label', (fs.hideLabel || 'Hide') + ' @' + author);
    btn.textContent = fs.hideText || 'Hide';
    btn.style.cssText = 'position:absolute;top:10px;right:52px;border:0;border-radius:12px;' +
      'padding:3px 9px;font:600 12px -apple-system,system-ui,sans-serif;background:rgba(127,127,127,.18);color:inherit';
    btn.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      if (fs.onHide) fs.onHide(author);
    }, true);
    wrap.appendChild(btn);
    post.insertBefore(wrap, post.firstChild);
  }

  /*
   * "You're all caught up": our card goes after the last shown post (or before the first post),
   * and everything after it inside <main> is hidden, so the rest of the list and the site's loader
   * stay out of view and loading stops. Our own element; the site's nodes are only hidden.
   */
  function insertCaughtUp(doc, f, anchorPost, before, fs) {
    if (!anchorPost) return;
    var row = rowOf(f, anchorPost);
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
   * Story viewer: ok only when the gate let this person through (allowed, or opened from their
   * profile: `ctx.storyUser`; highlights opened from a profile: `ctx.highlightFrom`) and the author
   * shown in the viewer header, if any, passes the same test. Marks <html data-bz-story-ok=path>;
   * CSS keeps the viewer hidden until then. Returns null when fine, else { user, author, back }
   * (`back` = the profile to return to, if the story was opened from one).
   */
  function runFriendsStory(c, doc, path, base, ctx) {
    var f = c.friends;
    var root = doc.documentElement;
    var user = f ? storyUserOf(f, path) : null;
    if (user === null) {
      if (root.hasAttribute(STORY_OK_ATTR)) root.removeAttribute(STORY_OK_ATTR);
      return null;
    }
    ctx = ctx || {};
    var opened = ctx.storyUser || null;
    var exempt = !!f.storyExempt[user];
    function passes(u) {
      if (!u || f.never[u]) return false;
      return allows(f, 'stories', u) || u === opened || (f.profileStories && u === ctx.highlightFrom);
    }
    // Only the viewer's own header counts. Until the site draws the viewer, the page we came from
    // is still in the DOM: its posts' headers (also hidden ones) and nav must never be read as the
    // story's author.
    var author = null;
    var heads = doc.querySelectorAll(f.storyAuthor);
    for (var i = 0; i < heads.length && !author; i++) {
      if (heads[i].closest('article') || heads[i].closest('nav') || (f.post && heads[i].closest(f.post))) continue;
      author = firstProfile(c, f, heads[i], base);
    }
    var ok = exempt ? passes(author) : passes(user) && (!author || author === user || passes(author));
    if (ok) {
      if (root.getAttribute(STORY_OK_ATTR) !== path) root.setAttribute(STORY_OK_ATTR, path);
      return null;
    }
    if (root.hasAttribute(STORY_OK_ATTR)) root.removeAttribute(STORY_OK_ATTR);
    // Exempt (highlights) with no author found yet: stay hidden, but it's not a violation yet.
    if (exempt && !author) return null;
    var back = opened || (exempt ? ctx.highlightFrom : null) || null;
    return { user: exempt ? author : user, author: author, back: back ? '/' + back + '/' : null };
  }

  /*
   * Search, "only matching": hide result rows whose account the feed rule doesn't allow. Rows that
   * become allowed again are shown. Profile links only (hrefs, never text); nav excluded. Returns
   * how many rows are hidden.
   */
  function runSearchFilter(c, doc, path, base) {
    var f = c.friends;
    if (!f || !c.searchMatching || !c.searchMatching.some(function (r) { return r.test(path); })) return 0;
    var anchors = doc.querySelectorAll('main a[href]');
    var total = doc.querySelectorAll('a[href]').length;
    var hidden = 0;
    for (var i = 0; i < anchors.length; i++) {
      var a = anchors[i];
      if (a.closest('nav')) continue;
      var u = profileUser(f, anchorPath(c, a, base));
      if (!u) continue;
      var row = safeAncestor(a, 1, doc, total);
      if (allows(f, 'feed', u)) {
        if (row.getAttribute(HIDDEN_ATTR) === 'ig.search.match') row.removeAttribute(HIDDEN_ATTR);
      } else {
        if (!row.hasAttribute(HIDDEN_ATTR)) row.setAttribute(HIDDEN_ATTR, 'ig.search.match');
        hidden++;
      }
    }
    return hidden;
  }

  /* Next allowed person after `user` in the tray order we saw. */
  function nextFriendStory(f, order, user) {
    var list = order || [];
    var i = list.indexOf(user);
    for (var k = i + 1; k < list.length; k++) {
      if (allows(f, 'stories', list[k])) return '/stories/' + list[k] + '/';
    }
    return null;
  }

  /*
   * List collector (manual scan and auto-scroll sync): on the user's own Followers / Following /
   * Close Friends page, read the usernames of profile links already on screen. Read-only; never
   * fetches. Close Friends: only rows whose checkbox is checked. `only` restricts it to one list.
   * Returns { list, owner, usernames } of names not sent before.
   */
  function runScan(c, doc, path, base, sent, only) {
    var sc = c.scan;
    if (!sc) return null;
    var list = null, owner = null;
    Object.keys(sc.routes).forEach(function (k) {
      if (list || (only && k !== only)) return;
      var m = sc.routes[k].exec(path);
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

  var SYNC_STOP_ROUTES = [
    { re: /^\/(challenge|checkpoint)(\/|$)/, event: 'challenge' },
    { re: /^\/accounts\/(suspended|disabled)(\/|$)/, event: 'challenge' },
    { re: /^\/accounts\/login(\/|$)/, event: 'login' }
  ];

  /*
   * Auto-scroll must stop at once when Instagram objects: a challenge/checkpoint or login page, or
   * any dialog that isn't the list itself (e.g. "Try again later"). Structure only, never text.
   * Returns 'challenge' | 'login' | 'warning' | null.
   */
  function syncWarning(c, doc, path, base) {
    for (var i = 0; i < SYNC_STOP_ROUTES.length; i++) {
      if (SYNC_STOP_ROUTES[i].re.test(path)) return SYNC_STOP_ROUTES[i].event;
    }
    var sc = c.scan;
    var dialogs = doc.querySelectorAll('[role="dialog"],[role="alertdialog"]');
    for (var j = 0; j < dialogs.length; j++) {
      var d = dialogs[j];
      if (d.closest('[data-bz]')) continue;
      var hasList = sc && firstProfile(c, sc, d, base) !== null;
      if (!hasList) return 'warning';
    }
    return null;
  }

  /* Delay before the next auto-scroll step (ms), from native's pacing and a random in [0, 1). */
  function syncDelay(pacing, step, random) {
    var p = pacing || {};
    var minStep = p.minStep || 2, maxStep = p.maxStep || 4;
    if (p.pauseEvery && step > 0 && step % p.pauseEvery === 0) {
      return Math.round(1000 * ((p.minPause || 8) + random * ((p.maxPause || 15) - (p.minPause || 8))));
    }
    return Math.round(1000 * (minStep + random * (maxStep - minStep)));
  }

  /*
   * Friends canaries: a post permalink visible outside any post container (the `post` selector no
   * longer matches, so default deny can't hide it), or a story link to someone the rules hide,
   * outside the tray selector. Offenders are blurred. Returns failed canary ids.
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
      if (f.postLink.test(p) && !a.closest(postSelector(f))) {
        safeAncestor(a, 3, doc, total).setAttribute(BLUR_ATTR, 'ig.canary.friendsPost');
        post = true;
      }
      var u = storyUserOf(f, p);
      if (u && !allows(f, 'stories', u) && !f.storyExempt[u] && !a.matches(f.storyTray)) {
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
    var f = c.friends;
    if (f) {
      var storyOwner = storyUserOf(f, path);
      if (storyOwner !== null) return storyDecision(f, storyOwner, here, previousPath, previous, state);
      state.storyUser = null;
    }
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
      css += ':is(' + postSelector(f) + '):not([' + FR_ATTR + '="ok"]){display:none!important}';
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
    var copy = { grant: state && state.grant ? state.grant : null, storyUser: state && state.storyUser ? state.storyUser : null };
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
   * `setInterval(fn, ms)` / `setTimeout(fn, ms)` instead of real timers, `now()` instead of
   * Date.now, `random()` instead of Math.random, `scrollOnce()` → { atBottom } instead of scrolling.
   */
  function install(win, config, hooks) {
    var doc = win.document;
    var replace = (hooks && hooks.replace) || function (u) { win.location.replace(u); };
    var assign = (hooks && hooks.assign) || function (u) { win.location.assign(u); };
    var clock = (hooks && hooks.now) || function () { return Date.now(); };
    var every = (hooks && hooks.setInterval) || function (fn, ms) { return win.setInterval(fn, ms); };
    var later = (hooks && hooks.setTimeout) || function (fn, ms) { return win.setTimeout(fn, ms); };
    var cancelLater = (hooks && hooks.clearTimeout) || function (t) { win.clearTimeout(t); };
    var random = (hooks && hooks.random) || Math.random;
    var c = compile(config.active);
    var limits = config.limits || { blocked: null };
    var lastViolationAt = 0;
    var state = config.state || { grant: null };
    if (state.storyUser === undefined) state.storyUser = null;
    var strings = config.strings || {};
    var lastHref = win.location.href;
    var ctx = { lastEndedAt: 0, lastGestureAt: 0, now: 0 };
    var scheduled = false;
    var overlay = null;
    // Feed rules: per-page state. The tray order survives the full loads a story skip does.
    var scanOn = !!config.scan;
    var syncCfg = config.sync || null;
    var sync = null;
    var fs = { postCount: -1, lastNewPostAt: 0, trayOrder: session('bz.tray') || [], card: null, cardHref: null,
               caughtUpText: strings.caughtUp, findingText: strings.finding, hideText: strings.hide, hideLabel: strings.hide,
               scanSent: {}, scanNoChecked: false, gaveUp: false, highlightFrom: session('bz.hl') || null,
               hiddenSeen: Object.create(null), onHide: hideAccount };

    /* One-tap hide: hidden here at once; native adds them to Never show (narrowing, instant). */
    function hideAccount(u) {
      if (c.friends) c.friends.never[u] = true;
      post({ type: 'hideAccount', username: u });
      schedule();
    }

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
      if (fs.cardHref !== null && fs.cardHref !== here) { removeCaughtUp(doc, fs); removeFinding(fs); fs.cardHref = null; }
      try { screenRoots(c, doc, path, win.location.href, [doc.documentElement], win); } catch (e) {
        post({ type: 'filterError', id: 'friends.screen' });
      }
      checkStory();
      schedule();
    }

    /* Story viewer: synchronous, so a story the rules hide is caught before the next frame. */
    function checkStory() {
      try {
        var v = runFriendsStory(c, doc, win.location.pathname, win.location.href,
          { storyUser: state.storyUser, highlightFrom: fs.highlightFrom });
        if (v) {
          violate({ reason: v.back ? 'bounced' : 'redirected', detail: null, ruleID: GATE_ID,
                    to: v.back || storyTarget(v.user) });
        }
      } catch (e) { post({ type: 'filterError', id: 'friends.story' }); }
    }

    /* Where a gated story goes from the feed: the next allowed person in the tray, else the feed. */
    function storyTarget(user) {
      var f = c.friends;
      if (!f) return c.landingPath;
      var next = nextFriendStory(f, fs.trayOrder, user);
      post({ type: 'friends', event: next ? 'storySkipped' : 'storyClosed' });
      return next || f.closePath;
    }

    /* Highlights carry no username in the URL: remember the profile they were opened from. */
    function noteHighlight(targetHref, fromHref) {
      var f = c.friends;
      if (!f) return;
      try {
        var to = new URL(targetHref, win.location.href).pathname;
        var owner = storyUserOf(f, to);
        if (owner === null) { fs.highlightFrom = null; session('bz.hl', null); return; }
        if (!f.storyExempt[owner] || !fromHref) return;
        var from = profileUser(f, new URL(fromHref, win.location.href).pathname);
        if (from) { fs.highlightFrom = from; session('bz.hl', from); }
      } catch (e) { /* keep the last context */ }
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
      try { runSearchFilter(c, doc, path, href); } catch (e) { post({ type: 'filterError', id: 'search.match' }); }
      var feedPass = null;
      try {
        feedPass = runFriendsFeed(c, doc, path, href, fs, clock(), win);
        if (fs.card && fs.cardHref === null) {
          fs.cardHref = path + win.location.search;
          post({ type: 'friends', event: 'caughtUp' });
        }
      } catch (e) { post({ type: 'filterError', id: 'friends.feed' }); }
      checkStory();
      if (scanOn && !sync) {
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
      if (feedPass && feedPass.hidden.length) post({ type: 'friendsHidden', usernames: feedPass.hidden.slice(0, 100) });
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
      if (d.type === 'redirect' && d.ruleID === GATE_ID && d.reason === 'redirected') d.to = storyTarget(storyUser(targetHref));
      if (d.type === 'allow') noteHighlight(targetHref, fromHref);
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
        // Already there (e.g. a story ring on the profile you're on): just don't go. No reload.
        if (d.to !== win.location.pathname + win.location.search) replace(d.to);
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

    /*
     * Mutations arrive here as a microtask, before the browser paints: screen exactly what changed
     * now (feed items, tray, story viewer, matching search), and leave the rest to the frame tick.
     */
    function onMutations(records) {
      try {
        var path = win.location.pathname;
        if (c.friends && isFeed(c.friends, path)) {
          var roots = [];
          for (var i = 0; i < records.length; i++) {
            var rec = records[i];
            roots.push(rec.target);
            if (rec.addedNodes) {
              for (var j = 0; j < rec.addedNodes.length; j++) {
                var node = rec.addedNodes[j];
                if (node.nodeType === 1 && !node.hasAttribute('data-bz')) roots.push(node);
              }
            }
          }
          screenRoots(c, doc, path, win.location.href, roots, win);
        }
        if (c.friends && c.friends.storyRoute.test(path)) checkStory();
        if (c.searchMatching) runSearchFilter(c, doc, path, win.location.href);
      } catch (e) {
        post({ type: 'filterError', id: 'friends.screen' });
      }
      schedule();
    }

    // Layer 4 trigger: synchronous screening, then the rest throttled with requestAnimationFrame.
    try {
      var mo = new win.MutationObserver(onMutations);
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
        if (v && v.ruleID === GATE_ID && v.reason === 'redirected') v.to = storyTarget(storyUser(win.location.href));
        if (v) violate(v);
        schedule();
      } catch (e) {
        post({ type: 'filterError', id: 'watchdog' });
      }
    }

    every(watchdog, 1000);
    ['hashchange', 'pageshow', 'focus'].forEach(function (t) { win.addEventListener(t, watchdog); });
    doc.addEventListener('visibilitychange', function () { if (!doc.hidden) watchdog(); });

    /*
     * Auto-scroll sync (ARCHITECTURE.md §4c rev. 2): visibly scroll the user's own list at native's
     * pace, reading names as they load. Stops at once on a challenge, login or dialog; reports the
     * end or a stall. Native decides caps and what to keep (SyncSession).
     */
    function setSync(next) {
      var same = next && syncCfg && next.list === syncCfg.list && next.owner === syncCfg.owner;
      syncCfg = next;
      if (same && sync) return;
      stopSync();
      if (syncCfg) startSync();
    }

    function startSync() {
      sync = { list: syncCfg.list, owner: syncCfg.owner, step: 0, quiet: 0, sent: {}, timer: null };
      sync.timer = later(syncStep, syncDelay(syncCfg.pacing, 0, random()));
    }

    function stopSync() {
      if (sync && sync.timer !== null) cancelLater(sync.timer);
      sync = null;
    }

    function endSync(event) {
      var list = sync ? sync.list : (syncCfg && syncCfg.list);
      stopSync();
      post({ type: 'syncEvent', list: list, event: event });
    }

    function scrollOnce() {
      if (hooks && hooks.scrollOnce) return hooks.scrollOnce();
      var first = doc.querySelector('main a[href]') || doc.querySelector('a[href]');
      var el = first;
      while (el && el !== doc.body) {
        var st = win.getComputedStyle(el);
        if ((st.overflowY === 'auto' || st.overflowY === 'scroll') && el.scrollHeight > el.clientHeight + 10) break;
        el = el.parentElement;
      }
      var box = el && el !== doc.body ? el : (doc.scrollingElement || doc.documentElement);
      var view = box === doc.scrollingElement || box === doc.documentElement ? win.innerHeight : box.clientHeight;
      box.scrollTop = box.scrollTop + Math.round(view * 0.8);
      return { atBottom: box.scrollTop + view >= box.scrollHeight - 4 };
    }

    function syncStep() {
      if (!sync || !syncCfg) return;
      sync.timer = null;
      try {
        var path = win.location.pathname;
        var w = syncWarning(c, doc, path, win.location.href);
        if (w) { endSync(w); return; }
        var r = runScan(c, doc, path, win.location.href, sync.sent, sync.list);
        if (!r || r.owner !== sync.owner) { endSync('leftPage'); return; }
        if (r.usernames.length) {
          sync.quiet = 0;
          post({ type: 'friendsScan', list: r.list, owner: r.owner, usernames: r.usernames });
        } else {
          sync.quiet++;
        }
        var pos = scrollOnce();
        if (sync.quiet >= 5) { endSync(pos.atBottom ? 'end' : 'stalled'); return; }
        sync.step++;
        sync.timer = later(syncStep, syncDelay(syncCfg.pacing, sync.step, random()));
      } catch (e) {
        post({ type: 'filterError', id: 'friends.sync' });
        endSync('stalled');
      }
    }

    /* Diagnostics (native calls these): the feed's structure, and a watch for painted unapproved posts. */
    win.__bzFeedReport = function () {
      return feedReport(c, doc, win.location.pathname, win.location.href);
    };
    win.__bzFlashWatch = function (ms) {
      return new Promise(function (resolve) {
        var end = clock() + (ms || 30000), frames = 0, flashFrames = 0, worst = 0;
        var raf = win.requestAnimationFrame || function (fn) { return win.setTimeout(fn, 16); };
        function frame() {
          frames++;
          var bad = paintedUnapproved(c, doc, win.location.pathname, win.location.href);
          if (bad) { flashFrames++; worst = Math.max(worst, bad); }
          if (clock() < end) raf(frame);
          else resolve({ frames: frames, flashFrames: flashFrames, worst: worst, report: feedReport(c, doc, win.location.pathname, win.location.href) });
        }
        raf(frame);
      });
    };

    // Native pushes new rules/limits here (budget ran out, schedule started) without a reload.
    // Page scripts could call it too; the native watchdog checks independently every second.
    win.__bzUpdate = function (next) {
      try {
        if (next && next.active) c = compile(next.active);
        if (next && next.limits) limits = next.limits;
        if (next && typeof next.scan === 'boolean') { scanOn = next.scan; fs.scanSent = {}; fs.scanNoChecked = false; }
        if (next && 'sync' in next) setSync(next.sync || null);
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
    if (syncCfg) startSync();

    return {
      state: state,
      get compiled() { return c; },
      get limits() { return limits; },
      tick: tick,
      refresh: refresh,
      watchdog: watchdog,
      ctx: ctx,
      friendsState: fs,
      get sync() { return sync; },
      syncStep: syncStep
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
    allows: allows,
    storyDecision: storyDecision,
    syncWarning: syncWarning,
    syncDelay: syncDelay,
    profileUser: profileUser,
    followingTarget: followingTarget,
    runFriendsFeed: runFriendsFeed,
    runFriendsStory: runFriendsStory,
    nextFriendStory: nextFriendStory,
    runScan: runScan,
    runSearchFilter: runSearchFilter,
    screenRoots: screenRoots,
    discoverPosts: discoverPosts,
    feedReport: feedReport,
    paintedUnapproved: paintedUnapproved,
    runFriendsCanaries: runFriendsCanaries,
    removeCaughtUp: removeCaughtUp,
    install: install
  };
});
