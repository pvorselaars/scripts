'use strict';
// public/note.js (the note view) against the real server, in the fake DOM.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { start, request } = require('./helpers.js');
const { loadPage } = require('./fakedom.js');

async function openNote(s, name) {
  const html = (await request(s.port, { path: `/note/${encodeURIComponent(name)}` })).text;
  const stateJson = /<script id="state" type="application\/json">([\s\S]*?)<\/script>/.exec(html)[1];
  return loadPage({ stateJson, base: `http://127.0.0.1:${s.port}`, script: 'note.js' });
}
const tags = (page, tag) => page.find(page.$('note'), (n) => n.tagName === tag);

const DOC = `# Selios

Intro paragraph with **bold**, a \`code\` span and
a second line of the same paragraph.

## Plan
- [ ] write the mailer [[other]]
- [x] already done
- plain bullet with [[ghost]]
1. first step
2. second step

> quoted
> text

\`\`\`
raw <b>block</b> [[not a link]]
\`\`\`
## Plan
See [the docs](https://docs.example/x) and [[selios#Plan|the plan]].
`;

test('renders headings, paragraphs, lists, quotes, code blocks, links and todos', async () => {
  const s = await start({ notes: { 'selios.md': DOC, 'other.md': 'x\n' } });
  try {
    const page = await openNote(s, 'selios');
    assert.equal(page.$('note-title').textContent, 'selios');
    assert.equal(page.document.title, 'selios');
    assert.deepEqual(tags(page, 'H2').map((h) => h.textContent), ['Selios'], 'a # heading is an h2 on this page (h1 is the title)');
    assert.deepEqual(tags(page, 'H3').map((h) => h.textContent), ['Plan', 'Plan'], 'and ## is an h3');
    assert.match(tags(page, 'P')[0].textContent, /^Intro paragraph with bold, a code span and a second line of the same paragraph\.$/);
    assert.deepEqual(tags(page, 'STRONG').map((n) => n.textContent), ['bold']);
    assert.equal(tags(page, 'OL').length, 1);
    assert.deepEqual(tags(page, 'OL')[0].children.map((li) => li.textContent), ['first step', 'second step']);
    assert.equal(tags(page, 'BLOCKQUOTE').length, 1);
    assert.equal(tags(page, 'BLOCKQUOTE')[0].textContent, 'quoted text');
    const pre = tags(page, 'PRE')[0];
    assert.equal(pre.textContent, 'raw <b>block</b> [[not a link]]', 'a code block is shown as it is');
    assert.equal(tags(page, 'INPUT').length, 2, 'two todos');
    assert.deepEqual(tags(page, 'INPUT').map((i) => i.checked), [false, true]);
  } finally { s.close(); }
});

test('wiki links: existing notes link normally, missing ones are marked, aliases and headings work', async () => {
  const s = await start({ notes: { 'selios.md': DOC, 'other.md': 'x\n' } });
  try {
    const page = await openNote(s, 'selios');
    const links = tags(page, 'A').map((a) => [a.textContent, a.href, a.className]);
    assert.deepEqual(links, [
      ['other', '/note/other', 'wiki'],
      ['ghost', '/note/ghost', 'wiki missing'],
      ['the docs', 'https://docs.example/x', 'ext'],
      ['the plan', '/note/selios#plan', 'wiki'],
    ]);
    assert.ok(tags(page, 'A').filter((a) => a.className === 'ext').every((a) => a.rel === 'noopener noreferrer'));
  } finally { s.close(); }
});

test('headings get anchors (repeats numbered), so [[note#heading]] can land on them', async () => {
  const s = await start({ notes: { 'selios.md': DOC } });
  try {
    const page = await openNote(s, 'selios');
    const headings = page.find(page.$('note'), (n) => n.tagName === 'H2' || n.tagName === 'H3');
    assert.deepEqual(headings.map((h) => h.id), ['selios', 'plan', 'plan-1']);
  } finally { s.close(); }
});

test('ticking a todo in the note view writes the right line of the right note', async () => {
  const s = await start({ notes: { 'selios.md': DOC, 'other.md': '- [ ] same text in another note\n' } });
  try {
    const page = await openNote(s, 'selios');
    const box = tags(page, 'INPUT')[0];
    box.checked = true;
    page.dispatch(box, 'change');
    await page.waitFor(() => !box.disabled);
    assert.equal(s.read('selios.md'), DOC.replace('- [ ] write the mailer', '- [x] write the mailer'));
    assert.equal(s.read('other.md'), '- [ ] same text in another note\n');
    box.checked = false;
    page.dispatch(box, 'change');
    await page.waitFor(() => !box.disabled);
    assert.equal(s.read('selios.md'), DOC);
  } finally { s.close(); }
});

test('if the note changed behind the page, the tick is reverted and the note is left alone', async () => {
  const s = await start({ notes: { 'selios.md': DOC } });
  try {
    const page = await openNote(s, 'selios');
    const edited = DOC.replace('write the mailer', 'something else');
    fs.writeFileSync(path.join(s.notesDir, 'selios.md'), edited);
    const box = tags(page, 'INPUT')[0];
    box.checked = true;
    page.dispatch(box, 'change');
    await page.waitFor(() => !box.disabled);
    assert.equal(box.checked, false);
    assert.match(page.$('status').textContent, /changed or is gone/);
    assert.equal(s.read('selios.md'), edited);
  } finally { s.close(); }
});

test('backlinks: listed with a snippet and a link; hidden when nothing links here', async () => {
  const s = await start({ notes: { 'selios.md': 'x\n', 'a.md': 'about [[selios]] and **more**\n', '2026-10-02.md': '- [ ] mail [[selios|Selios]]\n', 'lonely.md': 'z\n' } });
  try {
    const page = await openNote(s, 'selios');
    assert.equal(page.$('backlinks').hidden, false);
    const items = page.$('backlink-list').children;
    assert.deepEqual(items.map((li) => li.children[0].textContent), ['2026-10-02', 'a'], 'daily notes first');
    assert.deepEqual(items.map((li) => li.children[0].href), ['/note/2026-10-02', '/note/a']);
    assert.match(items[1].textContent, /about selios and more/);
    assert.equal(items[0].children[1].textContent, 'mail Selios', 'list and todo markers are stripped from the snippet');
    const lonely = await openNote(s, 'lonely');
    assert.equal(lonely.$('backlinks').hidden, true);
  } finally { s.close(); }
});

test('a note that does not exist yet says so, and still shows what links to it', async () => {
  const s = await start({ notes: { 'a.md': 'plan [[ghost]] soon\n' } });
  try {
    const page = await openNote(s, 'ghost');
    assert.equal(page.$('note-title').textContent, 'ghost');
    assert.match(tags(page, 'P')[0].textContent, /There is no note called “ghost” yet\./);
    assert.equal(tags(page, 'INPUT').length, 0);
    assert.equal(page.$('backlinks').hidden, false);
  } finally { s.close(); }
});

test('hostile note content is only ever text; javascript: links are not links', async () => {
  const evil = '<img src=x onerror=alert(1)> <script>alert(2)</script>';
  const s = await start({ notes: { 'x.md': `# ${evil}\n${evil} [bad](javascript:alert(1)) [[ok]]\n- ${evil}\n\`\`\`\n${evil}\n\`\`\`\n` } });
  try {
    const page = await openNote(s, 'x');
    assert.deepEqual(page.created.map((n) => n.tagName).filter((t) => ['IMG', 'SCRIPT', 'IFRAME', 'STYLE', 'OBJECT'].includes(t)), []);
    const links = tags(page, 'A').map((a) => a.href);
    assert.deepEqual(links, ['/note/ok'], 'no javascript: anchor');
    assert.match(page.$('note').textContent, /\[bad\]\(javascript:alert\(1\)\)/, 'the unsafe link is shown as plain text');
    assert.ok(page.$('note').textContent.includes(evil));
  } finally { s.close(); }
});

test('Escape goes home, and the view refreshes when the tab becomes visible again', async () => {
  const s = await start({ notes: { 'n.md': 'first version\n' } });
  try {
    const page = await openNote(s, 'n');
    assert.match(page.$('note').textContent, /first version/);
    fs.writeFileSync(path.join(s.notesDir, 'n.md'), 'edited in nvim\n');
    page.document.listeners.visibilitychange.forEach((fn) => fn({}));
    await page.waitFor(() => /edited in nvim/.test(page.$('note').textContent));
    page.document.listeners.keydown.forEach((fn) => fn({ key: 'Escape' }));
    assert.equal(page.window.location.href, '/');
  } finally { s.close(); }
});
