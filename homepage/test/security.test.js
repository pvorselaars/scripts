'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const { start, request, post } = require('./helpers.js');

const NOTE = '- [ ] keep me\n';

test('rejects any Host header that is not this server (DNS rebinding)', async () => {
  const s = await start({ notes: { 'a.md': NOTE } });
  try {
    for (const host of ['evil.example.com', 'evil.example.com:80', `127.0.0.1.evil.com:${s.port}`, 'localhost', '127.0.0.1', `0.0.0.0:${s.port}`]) {
      const r = await request(s.port, { path: '/api/todos', headers: { Host: host } });
      assert.equal(r.status, 403, `Host ${JSON.stringify(host)} -> ${r.status}`);
    }
    for (const host of [`127.0.0.1:${s.port}`, `localhost:${s.port}`]) {
      assert.equal((await request(s.port, { path: '/api/todos', headers: { Host: host } })).status, 200);
    }
  } finally { s.close(); }
});

test('a request with no Host header at all is refused (HTTP/1.0)', async () => {
  const s = await start({ notes: { 'a.md': NOTE } });
  try {
    const reply = await new Promise((resolve, reject) => {
      const socket = net.connect(s.port, '127.0.0.1', () => socket.write('GET /api/todos HTTP/1.0\r\n\r\n'));
      let data = '';
      socket.on('data', (c) => { data += c; });
      socket.on('end', () => resolve(data));
      socket.on('error', reject);
    });
    assert.match(reply, /^HTTP\/1\.[01] 403/);
  } finally { s.close(); }
});

test('a POST from another website is refused: foreign Origin, wrong content type, no CORS headers', async () => {
  const s = await start({ notes: { 'a.md': NOTE } });
  try {
    const body = { file: 'a.md', line: 1, text: 'keep me', done: true };
    for (const origin of ['https://evil.example.com', 'null', 'http://127.0.0.1:1', `http://evil.com:${s.port}`]) {
      const r = await post(s.port, '/api/todos/toggle', body, { Origin: origin });
      assert.equal(r.status, 403, `Origin ${origin} -> ${r.status}`);
    }
    // a cross-site <form> can only send these content types, never application/json
    for (const type of ['text/plain', 'application/x-www-form-urlencoded', 'multipart/form-data; boundary=x']) {
      const r = await request(s.port, { method: 'POST', path: '/api/todos/toggle', body: JSON.stringify(body), headers: { 'Content-Type': type } });
      assert.equal(r.status, 415, type);
    }
    assert.equal(s.read('a.md'), NOTE, 'the note must be untouched');
    const ok = await post(s.port, '/api/todos/toggle', body, { Origin: `http://127.0.0.1:${s.port}` });
    assert.equal(ok.status, 200);
    const preflight = await request(s.port, { method: 'OPTIONS', path: '/api/todos/toggle', headers: { Origin: 'https://evil.example.com', 'Access-Control-Request-Method': 'POST' } });
    assert.equal(preflight.headers['access-control-allow-origin'], undefined);
    assert.equal((await request(s.port, { path: '/api/todos' })).headers['access-control-allow-origin'], undefined);
  } finally { s.close(); }
});

test('oversized and malformed bodies are refused', async () => {
  const s = await start({ notes: { 'a.md': NOTE } });
  try {
    assert.equal((await post(s.port, '/api/todos/add', { text: 'x'.repeat(20_000) })).status, 413);
    assert.equal((await post(s.port, '/api/todos/add', '[1,2')).status, 400);
    assert.equal(s.read('a.md'), NOTE);
  } finally { s.close(); }
});

test('only the known routes exist; no directory listing, no file reads outside the public files', async () => {
  const s = await start({ notes: { 'a.md': NOTE } });
  try {
    for (const p of ['/server.js', '/package.json', '/../server.js', '/%2e%2e/server.js', '/public/app.js', '/api', '/api/todos/toggle', '/a.md', '/etc/passwd', '/wallpaper/../../etc/passwd']) {
      const r = await request(s.port, { path: p });
      assert.ok([404, 405, 400].includes(r.status) || r.status === 403, `${p} -> ${r.status}`);
      assert.doesNotMatch(r.text, /createServer|root:/, `${p} leaked content`);
    }
    assert.equal((await request(s.port, { method: 'PUT', path: '/api/todos/add', body: '{}', headers: { 'Content-Type': 'application/json' } })).status, 404);
  } finally { s.close(); }
});

test('responses carry no-store for API data and nosniff everywhere', async () => {
  const s = await start({ notes: { 'a.md': NOTE } });
  try {
    const r = await request(s.port, { path: '/api/todos' });
    assert.equal(r.headers['cache-control'], 'no-store');
    assert.equal(r.headers['x-content-type-options'], 'nosniff');
  } finally { s.close(); }
});
