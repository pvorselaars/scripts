'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { start, request, tempDir, makePlaces } = require('./helpers.js');
const lib = require('../public/lib.js');

const publicDir = path.join(__dirname, '..', 'public');

test('search box: same rules as the web-search script', () => {
  const ddg = (q) => 'https://duckduckgo.com/?q=' + encodeURIComponent(q);
  const cases = [
    ['https://example.com/a?b=1', 'url', 'https://example.com/a?b=1'], ['example.com', 'url', 'https://example.com'],
    ['github.com/pvorselaars/dotfiles', 'url', 'https://github.com/pvorselaars/dotfiles'], ['localhost:8080/api', 'url', 'http://localhost:8080/api'],
    ['192.168.1.1', 'url', 'http://192.168.1.1'], ['sway keybindings', 'search', ddg('sway keybindings')],
    ['what is c++ & rust?', 'search', ddg('what is c++ & rust?')], ['!yt lofi beats', 'search', ddg('!yt lofi beats')],
    ['?main.py', 'search', ddg('main.py')], ['  hello  ', 'search', ddg('hello')], ['my.site is down', 'search', ddg('my.site is down')],
  ];
  for (const [input, type, url] of cases) assert.deepEqual(lib.classifyInput(input), { type, url }, input);
  assert.equal(lib.classifyInput(''), null);
  assert.equal(lib.classifyInput('   '), null);
  assert.equal(lib.classifyInput(undefined), null);
});

test('search box: dangerous schemes are searched for, never opened', () => {
  for (const input of ['javascript:alert(1)', 'data:text/html,<script>alert(1)</script>', 'file:///etc/passwd', 'ssh://host', 'vbscript:x']) {
    assert.equal(lib.classifyInput(input).type, 'search', input);
  }
});

test('code spans split into text and code parts, with no markup produced', () => {
  assert.deepEqual(lib.splitCode('a `b` c'), [{ text: 'a ' }, { text: 'b', code: true }, { text: ' c' }]);
  assert.deepEqual(lib.splitCode('no code'), [{ text: 'no code' }]);
  assert.deepEqual(lib.splitCode('`x``y`'), [{ text: 'x', code: true }, { text: 'y', code: true }]);
  assert.deepEqual(lib.splitCode('<img src=x onerror=alert(1)>'), [{ text: '<img src=x onerror=alert(1)>' }]);
  assert.deepEqual(lib.splitCode('unclosed `tick'), [{ text: 'unclosed `tick' }]);
});

test('greeting follows the hour; clock is zero padded; only http(s) links are used', () => {
  const at = (h) => new Date(2026, 9, 23, h, 5);
  assert.deepEqual([2, 8, 13, 20].map((h) => lib.greeting(at(h))), ['Good night', 'Good morning', 'Good afternoon', 'Good evening']);
  assert.equal(lib.formatClock(at(7)), '07:05');
  assert.equal(lib.safeHref('https://a.example'), 'https://a.example');
  assert.equal(lib.safeHref('http://a.example'), 'http://a.example');
  for (const bad of ['javascript:alert(1)', 'data:text/html,x', 'file:///etc/passwd', '//evil.com', '']) assert.equal(lib.safeHref(bad), null, bad);
});

test('the page embeds its state, and hostile note text or bookmark titles cannot break out of it', async () => {
  const evil = '</script><script>window.pwned=1</script><img src=x onerror=alert(1)> ';
  const profile = tempDir('profile-');
  makePlaces(profile, [[evil, 'https://ok.example/']]);
  const s = await start({ notes: { 'x.md': `- [ ] ${evil}\n` }, profile });
  try {
    const r = await request(s.port, { path: '/' });
    assert.equal(r.status, 200);
    assert.ok(!r.text.includes('</script><script>window.pwned'), 'a note must not be able to close the state script block');
    const json = /<script id="state" type="application\/json">([\s\S]*?)<\/script>/.exec(r.text);
    assert.ok(json, 'state block present');
    const state = JSON.parse(json[1]);
    assert.equal(state.name, 'Tester');
    assert.equal(state.todos.notes[0].todos[0].text, evil, 'the text survives the round trip unchanged');
    assert.equal(state.bookmarks[0].title, evil);
  } finally { s.close(); fs.rmSync(profile, { recursive: true, force: true }); }
});

test('the page is served with a strict content security policy and no store caching', async () => {
  const s = await start();
  try {
    const r = await request(s.port, { path: '/' });
    assert.equal(r.headers['cache-control'], 'no-store');
    const csp = r.headers['content-security-policy'];
    for (const rule of ["default-src 'none'", "script-src 'self'", "connect-src 'self'", "frame-ancestors 'none'", "base-uri 'none'", "form-action 'none'"]) assert.ok(csp.includes(rule), rule);
    assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|\*/);
    assert.match(r.headers['content-type'], /^text\/html/);
  } finally { s.close(); }
});

test('assets are served with the right types', async () => {
  const s = await start();
  try {
    for (const [file, type] of [['style.css', /^text\/css/], ['app.js', /^text\/javascript/], ['lib.js', /^text\/javascript/]]) {
      const r = await request(s.port, { path: `/${file}` });
      assert.equal(r.status, 200, file);
      assert.match(r.headers['content-type'], type, file);
    }
  } finally { s.close(); }
});

test('the page code never parses text as HTML and never talks to another site', () => {
  const code = ['app.js', 'lib.js'].map((f) => fs.readFileSync(path.join(publicDir, f), 'utf8')).join('\n');
  for (const banned of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function', 'setTimeout("', "setTimeout('"]) {
    assert.ok(!code.includes(banned), `${banned} must not be used`);
  }
  const html = fs.readFileSync(path.join(publicDir, 'index.html'), 'utf8') + fs.readFileSync(path.join(publicDir, 'style.css'), 'utf8');
  assert.doesNotMatch(html, /https?:\/\/(?!duckduckgo)/, 'no external resources in the HTML or CSS');
  assert.doesNotMatch(html, /\sstyle=|\son\w+=/i, 'no inline styles or handlers (the CSP forbids them)');
});
