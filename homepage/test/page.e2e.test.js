'use strict';
// The real public/app.js against the real server, in a fake DOM: what happens on the page AND in the note files.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { start, request, today } = require('./helpers.js');
const { loadPage } = require('./fakedom.js');

async function open(s) {
  const html = (await request(s.port, { path: '/' })).text;
  const stateJson = /<script id="state" type="application\/json">([\s\S]*?)<\/script>/.exec(html)[1];
  return loadPage({ stateJson, base: `http://127.0.0.1:${s.port}` });
}
const checkboxes = (page) => page.find(page.$('todo-groups'), (n) => n.tagName === 'INPUT');

const NOTES = { '2026-10-02.md': '- [ ] first thing\n- [ ] second `thing`\n', '2026-10-01.md': '- [ ] older\n- [x] already done\n' };

test('renders groups, todos and the open count from the embedded state', async () => {
  const s = await start({ notes: NOTES });
  try {
    const page = await open(s);
    assert.equal(page.$('todo-count').textContent, '(3)');
    const groups = page.find(page.$('todo-groups'), (n) => n.tagName === 'SECTION');
    assert.deepEqual(groups.map((g) => g.children[0].textContent), ['2026-10-02', '2026-10-01']);
    assert.equal(checkboxes(page).length, 3, 'done todos are hidden');
    assert.deepEqual(page.find(page.$('todo-groups'), (n) => n.tagName === 'CODE').map((n) => n.textContent), ['thing']);
    assert.equal(page.$('greeting').textContent.endsWith(', Tester'), true);
  } finally { s.close(); }
});

test('ticking a todo writes [x] into the note, keeps the item visible and updates the count', async () => {
  const s = await start({ notes: NOTES });
  try {
    const page = await open(s);
    const box = checkboxes(page)[0];
    box.checked = true;
    page.dispatch(box, 'change');
    await page.waitFor(() => !box.disabled);
    assert.equal(s.read('2026-10-02.md'), '- [x] first thing\n- [ ] second `thing`\n');
    assert.equal(s.read('2026-10-01.md'), NOTES['2026-10-01.md'], 'other notes untouched');
    assert.equal(page.$('todo-count').textContent, '(2)');
    assert.equal(checkboxes(page)[0].checked, true, 'still shown, ticked');
    // and back
    box.checked = false;
    page.dispatch(box, 'change');
    await page.waitFor(() => !box.disabled);
    assert.equal(s.read('2026-10-02.md'), NOTES['2026-10-02.md']);
    assert.equal(page.$('todo-count').textContent, '(3)');
  } finally { s.close(); }
});

test('if the note changed behind the page, the tick is reverted, an error is shown, and the note is left alone', async () => {
  const s = await start({ notes: NOTES });
  try {
    const page = await open(s);
    const edited = '- [ ] something else entirely\n- [ ] second `thing`\n';
    fs.writeFileSync(path.join(s.notesDir, '2026-10-02.md'), edited);
    const box = checkboxes(page)[0];
    box.checked = true;
    page.dispatch(box, 'change');
    await page.waitFor(() => !box.disabled);
    assert.equal(box.checked, false, 'tick reverted');
    assert.match(page.$('status').textContent, /changed or is gone/);
    assert.equal(s.read('2026-10-02.md'), edited);
  } finally { s.close(); }
});

test('adding a todo appends it to today\'s note and shows it under Today', async () => {
  const s = await start({ notes: NOTES });
  try {
    const page = await open(s);
    page.$('add-text').value = 'write the homepage tests';
    page.dispatch(page.$('add'), 'submit');
    await page.waitFor(() => page.$('add-text').value === '' && !page.$('add-text').disabled);
    assert.equal(s.read(`${today}.md`), '- [ ] write the homepage tests\n');
    const groups = page.find(page.$('todo-groups'), (n) => n.tagName === 'SECTION');
    assert.equal(groups[0].children[0].textContent, 'Today');
    assert.match(groups[0].textContent, /write the homepage tests/);
    assert.equal(page.$('todo-count').textContent, '(4)');
    // empty input does nothing
    page.dispatch(page.$('add'), 'submit');
    assert.equal(s.read(`${today}.md`), '- [ ] write the homepage tests\n');
  } finally { s.close(); }
});

test('hostile todo text is shown as text, never as elements', async () => {
  const evil = '<img src=x onerror=alert(1)> <script>alert(2)</script>';
  const s = await start({ notes: { 'x.md': `- [ ] ${evil} [[link]]\n` } });
  try {
    const page = await open(s);
    assert.ok(page.find(page.$('todo-groups'), (n) => n.textContent.includes(evil)).length > 0, 'the text is shown');
    assert.deepEqual(page.created.map((n) => n.tagName).filter((t) => ['IMG', 'SCRIPT', 'IFRAME'].includes(t)), []);
    // the [[link]] next to the hostile text is the one and only link: a plain, safe <a>
    const links = page.created.filter((n) => n.tagName === 'A');
    assert.equal(links.length, 1);
    assert.deepEqual([links[0].href, links[0].textContent, links[0].className], ['/note/link', 'link', 'wiki missing']);
    page.$('add-text').value = evil;
    page.dispatch(page.$('add'), 'submit');
    await page.waitFor(() => page.$('add-text').value === '');
    assert.deepEqual(page.created.map((n) => n.tagName).filter((t) => ['IMG', 'SCRIPT', 'IFRAME'].includes(t)), []);
  } finally { s.close(); }
});

test('search: urls open, text searches DuckDuckGo, empty does nothing', async () => {
  const s = await start();
  try {
    const page = await open(s);
    const submit = (text) => { page.$('q').value = text; page.dispatch(page.$('search'), 'submit'); return page.window.location.href; };
    assert.equal(submit('example.com'), 'https://example.com');
    assert.equal(submit('sway keybindings'), 'https://duckduckgo.com/?q=sway%20keybindings');
    assert.equal(submit('!yt lofi'), 'https://duckduckgo.com/?q=!yt%20lofi', 'bangs reach DuckDuckGo intact');
    const before = page.window.location.href;
    assert.equal(submit('   '), before);
    assert.equal(submit('javascript:alert(1)').startsWith('https://duckduckgo.com/?q='), true);
  } finally { s.close(); }
});

test('keyboard: "/" focuses search, "n" focuses the todo box, Escape leaves, typing does not trigger shortcuts', async () => {
  const s = await start();
  try {
    const page = await open(s);
    const keydown = (key, extra = {}) => page.document.listeners.keydown.forEach((fn) => fn({ key, preventDefault() {}, ...extra }));
    keydown('/');
    assert.equal(page.document.activeElement, page.$('q'));
    keydown('n');
    assert.equal(page.document.activeElement, page.$('q'), 'while typing in an input, n is just a letter');
    keydown('Escape');
    assert.equal(page.document.activeElement, page.document.body);
    keydown('n');
    assert.equal(page.document.activeElement, page.$('add-text'));
    keydown('Escape');
    keydown('/', { ctrlKey: true });
    assert.equal(page.document.activeElement, page.document.body, 'ctrl+/ is left alone');
  } finally { s.close(); }
});

test('the page keeps itself fresh: refetches todos when the tab becomes visible', async () => {
  const s = await start({ notes: NOTES });
  try {
    const page = await open(s);
    assert.equal(page.$('todo-count').textContent, '(3)');
    fs.appendFileSync(path.join(s.notesDir, '2026-10-02.md'), '- [ ] added in nvim\n');
    page.document.hidden = false;
    page.document.listeners.visibilitychange.forEach((fn) => fn({}));
    await page.waitFor(() => page.$('todo-count').textContent === '(4)');
  } finally { s.close(); }
});

test('wiki links in a todo: to an existing note, to a missing note, with an alias', async () => {
  const s = await start({ notes: { 'selios.md': 'x\n', '2026-10-02.md': '- [ ] mail [[selios]] and [[ghost]] and [[Selios#Plan|the plan]]\n' } });
  try {
    const page = await open(s);
    const links = page.find(page.$('todo-groups'), (n) => n.tagName === 'A').map((a) => [a.textContent, a.href, a.className]);
    assert.deepEqual(links, [['selios', '/note/selios', 'wiki'], ['ghost', '/note/ghost', 'wiki missing'], ['the plan', '/note/Selios#plan', 'wiki']]);
    assert.match(page.find(page.$('todo-groups'), (n) => n.tagName === 'LABEL')[0].textContent, /^mail selios and ghost and the plan$/);
  } finally { s.close(); }
});
