'use strict';
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { createServer, localDate } = require('../server.js');

const today = localDate();

function tempDir(prefix = 'homepage-test-') { return fs.mkdtempSync(path.join(os.tmpdir(), prefix)); }

// a notes folder, wallpaper folder and server on an ephemeral port
async function start({ notes = {}, wallpapers = {}, log = () => {} } = {}) {
  const notesDir = tempDir('notes-');
  const wallpaperDir = tempDir('wall-');
  for (const [name, content] of Object.entries(notes)) fs.writeFileSync(path.join(notesDir, name), content);
  for (const [name, content] of Object.entries(wallpapers)) fs.writeFileSync(path.join(wallpaperDir, name), content);
  const cfg = {
    host: '127.0.0.1', port: 0, notesDir, wallpaperDir,
    name: 'Tester', log, publicDir: path.join(__dirname, '..', 'public'),
  };
  const server = createServer(cfg);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  const read = (name) => fs.readFileSync(path.join(notesDir, name), 'utf8');
  const close = () => { server.close(); fs.rmSync(notesDir, { recursive: true, force: true }); fs.rmSync(wallpaperDir, { recursive: true, force: true }); };
  return { cfg, port, notesDir, read, close };
}

// raw request, so tests can set Host and Origin
function request(port, { method = 'GET', path: p = '/', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: p, headers: { Host: `127.0.0.1:${port}`, ...headers } }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const buffer = Buffer.concat(chunks);
        let json = null;
        try { json = JSON.parse(buffer.toString('utf8')); } catch { /* not json */ }
        resolve({ status: res.statusCode, headers: res.headers, buffer, text: buffer.toString('utf8'), json });
      });
    });
    req.on('error', reject);
    if (body !== undefined) req.write(typeof body === 'string' ? body : JSON.stringify(body));
    req.end();
  });
}

const post = (port, p, body, headers = {}) => request(port, { method: 'POST', path: p, body, headers: { 'Content-Type': 'application/json', ...headers } });

module.exports = { today, tempDir, start, request, post };
