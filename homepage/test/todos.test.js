'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { start, request, post, today, unique } = require('./helpers.js');

const NOTE = '- [ ] first\n- [x] done one\nplain text\n- [ ] third `code`\n';

test('lists todos grouped by note, today first, then daily notes newest first, then other notes', async () => {
  const s = await start({ notes: {
    '2026-10-01.md': '- [ ] old daily\n', '2026-10-05.md': '- [ ] newer daily\n', 'ideas.md': '- [ ] an idea\n',
    [`${today}.md`]: '- [ ] today thing\n', 'empty.md': 'no todos here\n',
  } });
  try {
    const r = await request(s.port, { path: '/api/todos' });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.notes.map((n) => n.title), [today, '2026-10-05', '2026-10-01', 'ideas']);
    assert.deepEqual(r.json.notes.map((n) => n.kind), ['today', 'daily', 'daily', 'note']);
    assert.equal(r.json.today, today);
  } finally { s.close(); }
});

test('parses todo lines: text, done state, line number, nesting; ignores non-todos', async () => {
  const s = await start({ notes: { 'a.md': NOTE + '  - [ ] nested\n' } });
  try {
    const todos = (await request(s.port, { path: '/api/todos' })).json.notes[0].todos;
    assert.deepEqual(todos.map((t) => [t.line, t.text, t.done, t.indent]),
      [[1, 'first', false, 0], [2, 'done one', true, 0], [4, 'third `code`', false, 0], [5, 'nested', false, 1]]);
  } finally { s.close(); }
});

test('toggle changes exactly one line and nothing else (trailing newline and mode kept)', async () => {
  const s = await start({ notes: { 'a.md': NOTE } });
  try {
    fs.chmodSync(path.join(s.notesDir, 'a.md'), 0o640);
    const r = await post(s.port, '/api/todos/toggle', { file: 'a.md', line: 1, text: 'first', done: true });
    assert.equal(r.status, 200);
    assert.equal(s.read('a.md'), NOTE.replace('- [ ] first', '- [x] first'));
    assert.equal(fs.statSync(path.join(s.notesDir, 'a.md')).mode & 0o777, 0o640);
    const back = await post(s.port, '/api/todos/toggle', { file: 'a.md', line: 1, text: 'first', done: false });
    assert.equal(back.status, 200);
    assert.equal(s.read('a.md'), NOTE);
  } finally { s.close(); }
});

test('toggle is idempotent: setting the state it already has does not touch the file', async () => {
  const s = await start({ notes: { 'a.md': NOTE } });
  try {
    const before = fs.statSync(path.join(s.notesDir, 'a.md')).mtimeMs;
    const r = await post(s.port, '/api/todos/toggle', { file: 'a.md', line: 2, text: 'done one', done: true });
    assert.deepEqual(r.json, { ok: true, changed: false });
    assert.equal(fs.statSync(path.join(s.notesDir, 'a.md')).mtimeMs, before);
  } finally { s.close(); }
});

test('toggle finds the todo by its text when the line has shifted (a line was added above in nvim)', async () => {
  const s = await start({ notes: { 'a.md': 'new line above\n' + NOTE } });
  try {
    const r = await post(s.port, '/api/todos/toggle', { file: 'a.md', line: 1, text: 'first', done: true });
    assert.equal(r.status, 200);
    assert.equal(r.json.line, 2);
    assert.equal(s.read('a.md'), 'new line above\n' + NOTE.replace('- [ ] first', '- [x] first'));
  } finally { s.close(); }
});

test('toggle refuses (409) and leaves the note alone when the todo is gone or ambiguous', async () => {
  const s = await start({ notes: { 'gone.md': '- [ ] something else\n', 'dup.md': '- [ ] same\n- [ ] same\n' } });
  try {
    const gone = await post(s.port, '/api/todos/toggle', { file: 'gone.md', line: 1, text: 'first', done: true });
    assert.equal(gone.status, 409);
    assert.equal(s.read('gone.md'), '- [ ] something else\n');
    const dup = await post(s.port, '/api/todos/toggle', { file: 'dup.md', line: 9, text: 'same', done: true });
    assert.equal(dup.status, 409);
    assert.equal(s.read('dup.md'), '- [ ] same\n- [ ] same\n');
    // duplicates are fine when the line number still points at one of them
    const ok = await post(s.port, '/api/todos/toggle', { file: 'dup.md', line: 2, text: 'same', done: true });
    assert.equal(ok.status, 200);
    assert.equal(s.read('dup.md'), '- [ ] same\n- [x] same\n');
  } finally { s.close(); }
});

test('toggle keeps CRLF line endings', async () => {
  const s = await start({ notes: { 'win.md': '- [ ] one\r\n- [ ] two\r\n' } });
  try {
    await post(s.port, '/api/todos/toggle', { file: 'win.md', line: 2, text: 'two', done: true });
    assert.equal(s.read('win.md'), '- [ ] one\r\n- [x] two\r\n');
  } finally { s.close(); }
});

test('toggle only touches .md files directly inside the notes folder', async () => {
  const s = await start({ notes: { 'a.md': NOTE, 'secret.txt': '- [ ] nope\n' } });
  try {
    fs.mkdirSync(path.join(s.notesDir, 'sub'));
    fs.writeFileSync(path.join(s.notesDir, 'sub', 'b.md'), '- [ ] nested\n');
    const outside = path.join(s.notesDir, '..', `${unique('outside')}.md`);
    fs.writeFileSync(outside, '- [ ] outside\n');
    fs.symlinkSync(outside, path.join(s.notesDir, 'link.md'));
    const attempts = ['../etc/passwd', '../../x.md', 'sub/b.md', '/etc/passwd', 'secret.txt', '.hidden.md', 'a.md\0', 'link.md', ''];
    for (const file of attempts) {
      const r = await post(s.port, '/api/todos/toggle', { file, line: 1, text: 'nope', done: true });
      assert.ok([400, 404].includes(r.status), `${JSON.stringify(file)} -> ${r.status}`);
    }
    assert.equal(fs.readFileSync(outside, 'utf8'), '- [ ] outside\n');
    assert.equal(s.read('secret.txt'), '- [ ] nope\n');
    fs.rmSync(outside);
  } finally { s.close(); }
});

test('toggle validates its input', async () => {
  const s = await start({ notes: { 'a.md': NOTE } });
  try {
    for (const body of [{}, { file: 'a.md' }, { file: 'a.md', line: '1', text: 'first', done: true }, { file: 'a.md', line: 0, text: 'first', done: true },
      { file: 'a.md', line: 1, text: 5, done: true }, { file: 'a.md', line: 1, text: 'first', done: 'yes' }, { file: 7, line: 1, text: 'x', done: true }]) {
      assert.equal((await post(s.port, '/api/todos/toggle', body)).status, 400, JSON.stringify(body));
    }
    assert.equal((await post(s.port, '/api/todos/toggle', '{not json')).status, 400);
    assert.equal(s.read('a.md'), NOTE);
  } finally { s.close(); }
});

test('add appends to today\'s note, creating it, in the same format as quick-note', async () => {
  const s = await start();
  try {
    const r = await post(s.port, '/api/todos/add', { text: '  buy milk  ' });
    assert.equal(r.status, 200);
    assert.equal(r.json.file, `${today}.md`);
    assert.equal(s.read(`${today}.md`), '- [ ] buy milk\n');
    await post(s.port, '/api/todos/add', { text: 'second' });
    assert.equal(s.read(`${today}.md`), '- [ ] buy milk\n- [ ] second\n');
  } finally { s.close(); }
});

test('add does not glue onto a last line without a trailing newline, and flattens newlines', async () => {
  const s = await start({ notes: { [`${today}.md`]: 'no newline at the end' } });
  try {
    await post(s.port, '/api/todos/add', { text: 'line one\nline two' });
    assert.equal(s.read(`${today}.md`), 'no newline at the end\n- [ ] line one line two\n');
  } finally { s.close(); }
});

test('add rejects empty and oversized text', async () => {
  const s = await start();
  try {
    assert.equal((await post(s.port, '/api/todos/add', { text: '   ' })).status, 400);
    assert.equal((await post(s.port, '/api/todos/add', {})).status, 400);
    assert.equal((await post(s.port, '/api/todos/add', { text: 'x'.repeat(501) })).status, 400);
    assert.equal(fs.existsSync(path.join(s.notesDir, `${today}.md`)), false);
  } finally { s.close(); }
});

test('every write is logged (what changed and where), reads and no-op toggles are not', async () => {
  const lines = [];
  const s = await start({ notes: { 'a.md': NOTE }, log: (m) => lines.push(m) });
  try {
    await request(s.port, { path: '/api/todos' });
    await post(s.port, '/api/todos/toggle', { file: 'a.md', line: 1, text: 'first', done: true });
    await post(s.port, '/api/todos/toggle', { file: 'a.md', line: 1, text: 'first', done: true }); // already done: no write
    await post(s.port, '/api/todos/toggle', { file: 'a.md', line: 1, text: 'gone', done: true });  // refused
    await post(s.port, '/api/todos/add', { text: 'a new one' });
    assert.deepEqual(lines, ['toggle a.md:1 -> done: first', `add ${today}.md:1: a new one`]);
  } finally { s.close(); }
});
