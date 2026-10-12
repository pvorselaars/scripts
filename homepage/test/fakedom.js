'use strict';
// Just enough DOM to run public/app.js: elements, text, classList, events, focus.
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

class FakeNode {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.listeners = {};
    this.className = '';
    this.hidden = false;
    this.checked = false;
    this.disabled = false;
    this.value = '';
    this._text = '';
    this.style = { props: {}, setProperty(k, v) { this.props[k] = v; } };
    const self = this;
    this.classList = {
      _set() { return new Set(self.className.split(/\s+/).filter(Boolean)); },
      contains(c) { return this._set().has(c); },
      add(c) { const s = this._set(); s.add(c); self.className = [...s].join(' '); },
      toggle(c, force) { const s = this._set(); const on = force ?? !s.has(c); on ? s.add(c) : s.delete(c); self.className = [...s].join(' '); return on; },
    };
  }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this._text = String(v); this.children = []; }
  append(...nodes) { for (const n of nodes) this.children.push(typeof n === 'string' ? new FakeText(n) : n); }
  replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  focus() { this.ownerDocument.activeElement = this; }
  blur() { if (this.ownerDocument.activeElement === this) this.ownerDocument.activeElement = this.ownerDocument.body; }
}
class FakeText { constructor(t) { this.tagName = '#text'; this.textContent = t; this.children = []; } }

const IDS = ['clock', 'date', 'greeting', 'search', 'q', 'todos', 'todo-count', 'status', 'add', 'add-text', 'todo-groups', 'links', 'credit', 'state', 'bg'];

function walk(node, fn) { fn(node); for (const c of node.children ?? []) walk(c, fn); }

// run app.js against `stateJson` (the text of the embedded state block) and a base URL for fetch
function loadPage({ stateJson, base }) {
  const created = [];
  const timers = [];
  const document = {
    hidden: false, listeners: {}, byId: {},
    body: { tagName: 'BODY', blur() {} },
    getElementById(id) { return this.byId[id]; },
    createElement(tag) { const n = new FakeNode(tag); n.ownerDocument = this; created.push(n); return n; },
    createTextNode(t) { return new FakeText(t); },
    addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); },
  };
  document.activeElement = document.body;
  const TAGS = { q: 'input', 'add-text': 'input', search: 'form', add: 'form', links: 'nav' };
  for (const id of IDS) { const n = new FakeNode(TAGS[id] ?? 'div'); n.ownerDocument = document; document.byId[id] = n; }
  document.byId.state.textContent = stateJson;

  const context = vm.createContext({
    document, window: { location: { href: 'http://127.0.0.1/' } },
    fetch: (p, opts) => fetch(base + p, opts),
    setInterval: (fn, ms) => timers.push({ fn, ms }), setTimeout: (fn, ms) => timers.push({ fn, ms }),
    JSON, Set, Intl, Date, Promise, console, Image: class {},
  });
  const dir = path.join(__dirname, '..', 'public');
  vm.runInContext(fs.readFileSync(path.join(dir, 'lib.js'), 'utf8'), context);
  context.HomepageLib = context.HomepageLib ?? vm.runInContext('HomepageLib', context);
  vm.runInContext(fs.readFileSync(path.join(dir, 'app.js'), 'utf8'), context);

  const $ = (id) => document.byId[id];
  const dispatch = (node, type, event = {}) => { for (const fn of node.listeners[type] ?? []) fn({ preventDefault() {}, ...event }); };
  const find = (root, pred) => { const out = []; walk(root, (n) => { if (pred(n)) out.push(n); }); return out; };
  const waitFor = async (cond, ms = 3000) => {
    const start = Date.now();
    while (!cond()) { if (Date.now() - start > ms) throw new Error('timed out waiting for the page'); await new Promise((r) => setTimeout(r, 10)); }
  };
  return { $, document, window: context.window, created, dispatch, find, waitFor, timers };
}

module.exports = { loadPage };
