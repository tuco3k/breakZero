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
      })
    };
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
   * Install into a live page. `config` comes from native (LiteScriptBuilder):
   * { active: ActiveRecipe, state: {grant}, strings: {needsUpdate, report}, previousHref }
   * `hooks.replace(url)` overrides navigation (tests only; jsdom can't navigate).
   */
  function install(win, config, hooks) {
    var doc = win.document;
    var replace = (hooks && hooks.replace) || function (u) { win.location.replace(u); };
    var c = compile(config.active);
    var state = config.state || { grant: null };
    var strings = config.strings || {};
    var lastHref = win.location.href;
    var ctx = { lastEndedAt: 0, lastGestureAt: 0, now: 0 };
    var scheduled = false;
    var overlay = null;

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
      schedule();
    }

    function tick() {
      scheduled = false;
      var path = win.location.pathname;
      // Backstop: a URL change we didn't see (e.g. a router holding an old reference).
      if (win.location.href !== lastHref) onURLChanged(lastHref);
      runHeuristics(c, doc, path, win.location.href, post);
      var failed = runCanaries(c, doc, path, win.location.href, post);
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

    // The first document load: native already ran the same decision; this is the backstop.
    var first = check(win.location.href, config.previousHref || null);
    if (first.type === 'redirect') enforce(first, win.location.href);
    refresh();

    return {
      state: state,
      compiled: c,
      tick: tick,
      refresh: refresh,
      ctx: ctx
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
    install: install
  };
});
