// Small pure helpers, shared by the page (app.js) and the tests.
(function (root) {
  'use strict';

  const SEARCH = 'https://duckduckgo.com/?q=';

  // Same rules as the `web-search` script: URLs open, anything else is a DuckDuckGo search
  // (so !bangs work). A leading "?" forces a search.
  function classifyInput(raw) {
    let q = String(raw ?? '').trim();
    if (!q) return null;
    const search = (text) => ({ type: 'search', url: SEARCH + encodeURIComponent(text) });
    if (q.startsWith('?')) return search(q.slice(1).trim());
    if (/^(https?|ftp):\/\//i.test(q)) return { type: 'url', url: q };
    if (/^(localhost|\d{1,3}(\.\d{1,3}){3})(:\d+)?([/?#]|$)/.test(q)) return { type: 'url', url: 'http://' + q };
    if (!/\s/.test(q) && /^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?([/?#]|$)/i.test(q)) return { type: 'url', url: 'https://' + q };
    return search(q);
  }

  // "a `code` b" -> [{text:'a '}, {text:'code', code:true}, {text:' b'}]; never produces markup
  function splitCode(text) {
    const parts = [];
    const re = /`([^`]+)`/g;
    let last = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      if (m.index > last) parts.push({ text: text.slice(last, m.index) });
      parts.push({ text: m[1], code: true });
      last = m.index + m[0].length;
    }
    if (last < text.length) parts.push({ text: text.slice(last) });
    return parts;
  }

  function greeting(date) {
    const h = date.getHours();
    if (h < 5) return 'Good night';
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  const pad = (n) => String(n).padStart(2, '0');
  const formatClock = (date) => `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  const formatDate = (date) => new Intl.DateTimeFormat('en-GB', { weekday: 'long', day: 'numeric', month: 'long' }).format(date);

  // ---- inline markup: `code`, [[wiki links]], [text](https://url), **bold** -----------------------------
  // [[name]], [[name#heading]], [[name|alias]], [[name#heading|alias]] point at name.md (telekasten style)
  const INLINE = /`([^`]+)`|\[\[([^\]\n|#]+?)(?:#([^\]\n|]+))?(?:\|([^\]\n]+))?\]\]|\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)|\*\*([^*\n]+)\*\*/g;

  // text -> parts: {text} | {text, code} | {text, wiki:{name, heading}} | {text, href} | {text, bold}; never markup
  function splitRich(text) {
    const parts = [];
    let last = 0;
    let m;
    INLINE.lastIndex = 0;
    while ((m = INLINE.exec(text)) !== null) {
      if (m.index > last) parts.push({ text: text.slice(last, m.index) });
      if (m[1] !== undefined) parts.push({ text: m[1], code: true });
      else if (m[2] !== undefined) parts.push({ text: (m[4] ?? m[2]).trim(), wiki: { name: m[2].trim(), heading: m[3] ? m[3].trim() : '' } });
      else if (m[5] !== undefined) parts.push({ text: m[5], href: m[6] });
      else parts.push({ text: m[7], bold: true });
      last = m.index + m[0].length;
    }
    if (last < text.length) parts.push({ text: text.slice(last) });
    return parts;
  }

  // anchors for [[note#heading]]: lowercase, spaces to dashes, punctuation dropped
  const slug = (heading) => String(heading).trim().toLowerCase().replace(/\s+/g, '-').replace(/[^\p{L}\p{N}_-]/gu, '');
  const noteHref = (name, heading) => '/note/' + encodeURIComponent(name) + (heading ? '#' + encodeURIComponent(slug(heading)) : '');

  // builds the inline parts into DOM nodes with textContent only; names = Set of lowercase note names
  function renderInline(doc, parent, text, names) {
    for (const part of splitRich(text)) {
      let node;
      if (part.code) { node = doc.createElement('code'); node.textContent = part.text; }
      else if (part.bold) { node = doc.createElement('strong'); node.textContent = part.text; }
      else if (part.href) {
        node = doc.createElement('a'); node.textContent = part.text; node.href = part.href;
        node.rel = 'noopener noreferrer'; node.className = 'ext';
      } else if (part.wiki) {
        node = doc.createElement('a'); node.textContent = part.text;
        node.href = noteHref(part.wiki.name, part.wiki.heading);
        node.className = names && !names.has(part.wiki.name.toLowerCase()) ? 'wiki missing' : 'wiki';
        node.title = part.wiki.name + (part.wiki.heading ? ' › ' + part.wiki.heading : '');
      } else node = doc.createTextNode(part.text);
      parent.append(node);
    }
  }

  const lib = { classifyInput, splitCode, splitRich, slug, noteHref, renderInline, greeting, formatClock, formatDate };
  if (typeof module !== 'undefined' && module.exports) module.exports = lib;
  else root.HomepageLib = lib;
})(typeof self !== 'undefined' ? self : this);
