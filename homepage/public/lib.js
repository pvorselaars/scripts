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

  const lib = { classifyInput, splitCode, greeting, formatClock, formatDate };
  if (typeof module !== 'undefined' && module.exports) module.exports = lib;
  else root.HomepageLib = lib;
})(typeof self !== 'undefined' ? self : this);
