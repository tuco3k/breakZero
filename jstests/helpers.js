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

function active(platform, settings = {}) {
  const r = recipe(platform);
  const toggles = settings.toggles || {};
  const on = (t) => (t in toggles ? toggles[t] : (r.toggles.find((x) => x.id === t) || { defaultOn: true }).defaultOn);
  const keep = (list) => (list || []).filter((x) => on(x.toggle));
  const out = Object.assign({}, r, {
    routes: (settings.customBlocks || []).map((p, i) => ({
      id: 'custom.block.' + i, toggle: 'custom', pattern: p.startsWith('^') ? p : '^' + p, action: 'block'
    })).concat(keep(r.routes)),
    hide: keep(r.hide).concat((settings.customHides || []).map((s, i) => ({ id: 'custom.hide.' + i, toggle: 'custom', selector: s }))),
    heuristics: keep(r.heuristics),
    behaviors: keep(r.behaviors),
    canaries: keep(r.canaries),
    resourceBlocks: keep(r.resourceBlocks)
  });
  const landingKey = settings.landing && r.landing.options[settings.landing] ? settings.landing : r.landing.default;
  return { recipe: out, landingPath: r.landing.options[landingKey] };
}

function dom(fixture, url) {
  const html = fs.readFileSync(path.join(__dirname, 'fixtures', fixture), 'utf8');
  return new JSDOM(html, { url, pretendToBeVisual: true });
}

module.exports = { bz, recipe, active, dom, KIT, SCRIPT };
