'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { start, request, today, unique } = require('./helpers.js');

const note = (s, name) => request(s.port, { path: `/api/note/${encodeURIComponent(name)}` });

test('a note comes back with its content, and the names of all notes', async () => {
  const s = await start({ notes: { 'selios.md': '# Selios\n- [ ] mail\n', 'other.md': 'x\n' } });
  try {
    const r = await note(s, 'selios');
    assert.equal(r.status, 200);
    assert.deepEqual([r.json.exists, r.json.name, r.json.file, r.json.content], [true, 'selios', 'selios.md', '# Selios\n- [ ] mail\n']);
    assert.deepEqual(r.json.names, ['other', 'selios']);
  } finally { s.close(); }
});

test('backlinks: every kind of link to the note, from other notes only, once per line', async () => {
  const s = await start({ notes: {
    'selios.md': 'self link [[selios]] must not count\n',
    'a.md': 'plain [[selios]]\nwith alias [[selios|the mail thing]]\nheading [[selios#Plan]] and again [[selios]] same line\nnot this [[selios2]] or [[other selios]]\n',
    'b.md': 'upper [[SELIOS]]\n',
    'c.md': 'no link here, just selios and [selios] and [[ selios ]]\n',
  } });
  try {
    const r = await note(s, 'selios');
    const byName = Object.fromEntries(r.json.backlinks.map((b) => [b.name, b.snippets]));
    assert.deepEqual(Object.keys(byName).sort(), ['a', 'b', 'c']);
    assert.equal(byName.a.length, 3, 'three lines in a.md link to it');
    assert.ok(byName.a.every((l) => !l.includes('selios2')));
    assert.deepEqual(byName.b, ['upper [[SELIOS]]']);
    assert.equal(byName.c.length, 1, 'spaces inside the brackets are ignored');
  } finally { s.close(); }
});

test('backlinks are ordered: today, daily notes newest first, then the others by name', async () => {
  const s = await start({ notes: {
    'zeta.md': '[[t]]\n', 'alpha.md': '[[t]]\n', '2026-10-01.md': '[[t]]\n', '2026-10-09.md': '[[t]]\n', [`${today}.md`]: '[[t]]\n',
  } });
  try {
    assert.deepEqual((await note(s, 't')).json.backlinks.map((b) => b.name), [today, '2026-10-09', '2026-10-01', 'alpha', 'zeta']);
  } finally { s.close(); }
});

test('a link finds the note whatever the case; an exact match wins', async () => {
  const s = await start({ notes: { 'Selios.md': 'upper\n', 'ideas.md': 'i\n' } });
  try {
    const r = await note(s, 'selios');
    assert.equal(r.json.exists, true);
    assert.equal(r.json.name, 'Selios');
    assert.equal(r.json.content, 'upper\n');
  } finally { s.close(); }
  const t = await start({ notes: { 'a.md': 'lower\n', 'A.md': 'upper\n' } });
  try { assert.equal((await note(t, 'A')).json.content, 'upper\n'); assert.equal((await note(t, 'a')).json.content, 'lower\n'); } finally { t.close(); }
});

test('a note that does not exist yet still lists what links to it', async () => {
  const s = await start({ notes: { 'a.md': 'plan [[ghost]] soon\n' } });
  try {
    const r = await note(s, 'ghost');
    assert.equal(r.status, 200);
    assert.deepEqual([r.json.exists, r.json.content, r.json.file], [false, null, null]);
    assert.deepEqual(r.json.backlinks, [{ name: 'a', snippets: ['plan [[ghost]] soon'] }]);
  } finally { s.close(); }
});

test('names with spaces and non-ASCII letters work', async () => {
  const s = await start({ notes: { 'my note.md': 'hello\n', 'Zürich ✓.md': 'x\n', 'a.md': '[[my note]] [[Zürich ✓]]\n' } });
  try {
    assert.equal((await note(s, 'my note')).json.content, 'hello\n');
    assert.equal((await note(s, 'Zürich ✓')).json.exists, true);
    assert.equal((await note(s, 'my note')).json.backlinks[0].name, 'a');
  } finally { s.close(); }
});

test('note names cannot reach outside the notes folder', async () => {
  const s = await start({ notes: { 'a.md': 'ok\n' } });
  try {
    const secret = path.join(s.notesDir, '..', `${unique('secret')}.md`);
    fs.writeFileSync(secret, 'TOP SECRET\n');
    for (const name of ['..', '../x', `../${path.basename(secret, '.md')}`, '/etc/passwd', '.hidden', 'a/b', 'a\\b', 'a\0b', 'x'.repeat(201), '']) {
      const r = await request(s.port, { path: `/api/note/${encodeURIComponent(name)}` });
      assert.ok([400, 404].includes(r.status) || r.json?.exists === false, `${JSON.stringify(name)} -> ${r.status} ${r.text.slice(0, 60)}`);
      assert.doesNotMatch(r.text, /TOP SECRET|root:/);
    }
    for (const raw of ['/api/note/%2e%2e%2f' + path.basename(secret, '.md'), '/api/note/..%2f..%2fetc%2fpasswd', '/api/note/%00', '/api/note/%ZZ', '/api/note/../todos']) {
      const r = await request(s.port, { path: raw });
      assert.doesNotMatch(r.text, /TOP SECRET|root:/, raw);
    }
    fs.rmSync(secret);
  } finally { s.close(); }
});

test('a symlink pointing outside the notes folder is not a note: not listed, not readable, not searched', async () => {
  const s = await start({ notes: { 'a.md': '[[link]]\n' } });
  try {
    const outside = path.join(s.notesDir, '..', `${unique('outside')}.md`);
    fs.writeFileSync(outside, '- [ ] outside todo [[a]]\n');
    fs.symlinkSync(outside, path.join(s.notesDir, 'link.md'));
    const r = await note(s, 'link');
    assert.equal(r.json.exists, false);
    assert.equal(r.json.content, null);
    assert.ok(!r.json.names.includes('link'));
    const todos = (await request(s.port, { path: '/api/todos' })).json;
    assert.ok(!todos.notes.some((n) => n.title === 'link'), 'its todos are not listed');
    assert.deepEqual((await note(s, 'a')).json.backlinks, [], 'and its text is not searched for backlinks');
    fs.rmSync(outside);
  } finally { s.close(); }
});

test('the todo list also returns every note name (for marking links to notes that do not exist yet)', async () => {
  const s = await start({ notes: { 'a.md': '- [ ] x\n', 'b.md': 'no todos\n' } });
  try { assert.deepEqual((await request(s.port, { path: '/api/todos' })).json.names, ['a', 'b']); } finally { s.close(); }
});

test('very large notes are cut off, not served whole', async () => {
  const s = await start({ notes: { 'big.md': 'x'.repeat(1_500_000) } });
  try { assert.equal((await note(s, 'big')).json.content.length, 1_000_000); } finally { s.close(); }
});

test('the note page embeds the note safely and carries the same security headers as the home page', async () => {
  const evil = '</script><script>window.pwned=1</script>';
  const s = await start({ notes: { 'x.md': `# ${evil}\n[[y]]\n` } });
  try {
    const r = await request(s.port, { path: '/note/x' });
    assert.equal(r.status, 200);
    assert.ok(!r.text.includes('</script><script>window.pwned'));
    const state = JSON.parse(/<script id="state" type="application\/json">([\s\S]*?)<\/script>/.exec(r.text)[1]);
    assert.equal(state.note.content, `# ${evil}\n[[y]]\n`);
    assert.equal(r.headers['cache-control'], 'no-store');
    assert.ok(r.headers['content-security-policy'].includes("script-src 'self'"));
    assert.equal((await request(s.port, { path: '/note/x', headers: { Host: 'evil.example' } })).status, 403);
    assert.doesNotMatch((await request(s.port, { path: '/note/%2e%2e' })).text, /"note":/, 'dot segments resolve before routing and never reach a note');
    assert.equal((await request(s.port, { path: '/note/%ZZ' })).status, 400);
  } finally { s.close(); }
});
